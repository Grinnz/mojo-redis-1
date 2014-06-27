package Mojo::Redis2;

=head1 NAME

Mojo::Redis2 - Pure-Perl non-blocking I/O Redis driver

=head1 VERSION

0.01

=head1 DESCRIPTION

L<Mojo::Redis2> is a pure-Perl non-blocking I/O L<Redis|http://redis.io>
driver for the L<Mojolicious> real-time framework.

Features:

=over 4

=item * Blocking support

L<Mojo::Redis2> support blocking methods. NOTE: Calling non-blocking and
blocking methods are supported on the same object, but might create a new
connection to the server.

=item * Error handling that makes sense

L<Mojo::Redis> was unable to report back errors that was bound to an operation.
L<Mojo::Redis2> on the other hand always make sure each callback receive an
error message on error.

=item * One object for different operations

L<Mojo::Redis> had only one connection, so it could not do more than on
blocking operation on the server side at the time (such as BLPOP,
SUBSCRIBE, ...). This object creates new connections pr. blocking operation
which makes it easier to avoid "blocking" bugs.

=item * Transaction support

Transactions will done in a new L<Mojo::Redis2> object that also act as a
guard: The transaction will not be run if the guard goes out of scope.

=back

=head1 SYNOPSIS

=head2 Blocking

  use Mojo::Redis2;
  my $redis = Mojo::Redis2->new;

  # Will die() on error.
  $res = $redis->set(foo => "42"); # $res = OK
  $res = $redis->get("foo");       # $res = 42

=head2 Non-blocking

  Mojo::IOLoop->delay(
    sub {
      my ($delay) = @_;
      # Will not run "GET foo" unless ping() was successful
      # Use pipelined() before ping() if you want all commands to run even
      # if one operation fail.
      $redis->ping($delay->begin)->get("foo", $delay->begin);
    },
    sub {
      my ($delay, $ping_err, $ping, $get_err, $get) = @_;
      # On error: $ping_err and $get_err is set to a string
      # On success: $ping = "PONG", $get = "42";
    },
  );

=head2 Pub/sub

L<Mojo::Redis2> can L</subscribe> and re-use the same object to C<publish> or
run other Redis commands, since it can keep track of multiple connections to
the same Redis server. It will also re-use the same connection when you
(p)subscribe multiple times.

  $self->on(message => sub {
    my ($self, $message, $channel) = @_;
  });

  $self->subscribe("some:channel" => sub {
    my ($self, $err) = @_;

    return $self->publish("myapp:errors" => $err) if $err;
    return $self->incr("subscribed:to:some:channel");
  });

=head2 Error handling

C<$err> in this document is a string containing an error message or
empty string on success.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::URL;
use Mojo::Util;
use Carp ();
use constant DEBUG => $ENV{MOJO_REDIS_DEBUG} || 0;
use constant DEFAULT_PORT => 6379;

our $VERSION = '0.01';

my $PROTOCOL_CLASS = do {
  my $class = $ENV{MOJO_REDIS_PROTOCOL} ||= eval "require Protocol::Redis::XS; 'Protocol::Redis::XS'" || 'Protocol::Redis';
  eval "require $class; 1" or die $@;
  $class;
};

my %REDIS_METHODS = map { ($_, 1) } (
  'append',   'decr',            'decrby',
  'del',      'exists',          'expire',           'expireat',    'get',              'getbit',
  'getrange', 'getset',          'hdel',             'hexists',     'hget',             'hgetall',
  'hincrby',  'hkeys',           'hlen',             'hmget',       'hmset',            'hset',
  'hsetnx',   'hvals',           'incr',             'incrby',      'keys',             'lindex',
  'linsert',  'llen',            'lpop',             'lpush',       'lpushx',           'lrange',
  'lrem',     'lset',            'ltrim',            'mget',        'move',             'mset',
  'msetnx',   'persist',         'ping',             'publish',     'randomkey',        'rename',
  'renamenx', 'rpop',            'rpoplpush',        'rpush',       'rpushx',           'sadd',
  'scard',    'sdiff',           'sdiffstore',       'set',         'setbit',           'setex',
  'setnx',    'setrange',        'sinter',           'sinterstore', 'sismember',        'smembers',
  'smove',    'sort',            'spop',             'srandmember', 'srem',             'strlen',
  'sunion',   'sunionstore',     'ttl',              'type',        'zadd',             'zcard',
  'zcount',   'zincrby',         'zinterstore',      'zrange',      'zrangebyscore',    'zrank',
  'zrem',     'zremrangebyrank', 'zremrangebyscore', 'zrevrange',   'zrevrangebyscore', 'zrevrank',
  'zscore',   'zunionstore',
);

=head1 EVENTS

=head2 connection

  $self->on(connection => sub { my ($self, $id) = @_; });

Emitted when a new connection has been established.

=head2 error

  $self->on(error => sub { my ($self, $err) = @_; ... });

Emitted if an error occurs that can't be associated with an operation.

=head2 message

  $self->on(message => sub {
    my ($self, $message, $channel) = @_;
  });

Emitted when a C<$message> is received on a C<$channel> after it has been
L<subscribed|/subscribe> to.

=head2 pmessage

  $self->on(pmessage => sub {
    my ($self, $message, $channel, $pattern) = @_;
  });

Emitted when a C<$message> is received on a C<$channel> matching a
C<$pattern>, after it has been L<subscribed|/psubscribe> to.

=head1 ATTRIBUTES

=head2 encoding

  $str = $self->encoding;
  $self = $self->encoding('UTF-8');

Holds the encoding using for data from/to Redis. Default is UTF-8.

=head2 protocol

  $obj = $self->protocol;
  $self = $self->protocol($obj);

Holds an object used to parse/generate Redis messages.
Defaults to L<Protocol::Redis::XS> or L<Protocol::Redis>.

L<Protocol::Redis::XS> need to be installed manually.

=cut

has encoding => 'UTF-8';
has protocol => sub { $PROTOCOL_CLASS->new(api => 1); };

=head2 url

  $self = $self->url("redis://x:$auth_key\@$server:$port/$database_index");
  $url = $self->url;

Holds a L<Mojo::URL> object with the location to the Redis server. Default
is C<redis://localhost:6379>.

=cut

sub url {
  return $_[0]->{url} ||= Mojo::URL->new($ENV{MOJO_REDIS_URL} || 'redis://localhost:6379') if @_ == 1;
  $_[0]->{url} = Mojo::URL->new($_[1]);
  $_[0];
}

=head1 METHODS

In addition to the methods listed in this module, you can call these Redis
methods on C<$self>:

append, decr, decrby,
del, exists, expire, expireat, get, getbit,
getrange, getset, hdel, hexists, hget, hgetall,
hincrby, hkeys, hlen, hmget, hmset, hset,
hsetnx, hvals, incr, incrby, keys, lindex,
linsert, llen, lpop, lpush, lpushx, lrange,
lrem, lset, ltrim, mget, move, mset,
msetnx, persist, ping, publish, randomkey, rename,
renamenx, rpop, rpoplpush, rpush, rpushx, sadd,
scard, sdiff, sdiffstore, set, setbit, setex,
setnx, setrange, sinter, sinterstore, sismember, smembers,
smove, sort, spop, srandmember, srem, strlen,
sunion, sunionstore, ttl, type, zadd, zcard,
zcount, zincrby, zinterstore, zrange, zrangebyscore, zrank,
zrem, zremrangebyrank, zremrangebyscore, zrevrange, zrevrangebyscore, zrevrank,
zscore and zunionstore.

=head2 new

  $self = Mojo::Redis2->new(...);

Object constructor. Makes sure L</url> is an object.

=cut

sub new {
  my $self = shift->SUPER::new(@_);
  $self->{url} = Mojo::URL->new($self->{url}) if $self->{url} and ref $self->{url} eq '';
  $self;
}

=head2 psubscribe

  $id = $self->psubscribe(@patterns, sub { my ($self, $err) = @_; ... });

Used to subscribe to specified channels that match C<@patterns>. See
L<http://redis.io/topics/pubsub> for details.

This event will cause L</pmessage> events to be emitted, unless C<$err> is set.

C<$id> can be used to L</unsubscribe>.

=head2 subscribe

  $id = $self->subscribe(@channels, sub { my ($self, $err = @_; ... });

Used to subscribe to specified C<@channels>. See L<http://redis.io/topics/pubsub>
for details.

This event will cause L</message> events to be emitted, unless C<$err> is set.

C<$id> can be used to L</unsubscribe>.

=cut

sub psubscribe { shift->_subscribe(PSUBSCRIBE => @_); }
sub subscribe { shift->_subscribe(SUBSCRIBE => @_); }

sub AUTOLOAD {
  my $self = shift;
  my ($package, $method) = split /::(\w+)$/, our $AUTOLOAD;
  my $op = uc $method;

  unless ($REDIS_METHODS{$method}) {
    Carp::croak(qq{Can't locate object method "$method" via package "$package"});
  }

  eval "sub $method { shift->prepare($op => \@_); }; 1" or die $@;
  $self->prepare($op => @_);
}

sub DESTROY { shift->_cleanup; }

sub _cleanup {
  my $self = shift;
  my $connections = delete $self->{connections};

  delete $self->{pid};

  for my $id (keys %$connections) {
    my $c = $connections->{$id};
    my $cb = $c->{cb};
    my $loop = $self->_loop($c->{nb}) or next;
    $loop->remove($id);
    $self->$cb('Premature connection close', []) if $cb and $c->{queue};
  }
}

sub _connect {
  my ($self, $op) = @_;
  my $url = $self->url;
  my $id;

  Scalar::Util::weaken($self);
  $id = $self->_loop($op->{nb})->client(
    { address => $url->host, port => $url->port || DEFAULT_PORT },
    sub {
      my ($loop, $err, $stream) = @_;

      if ($err) {
        delete $self->{connections}{$id};
        return $self->_error($id, $err);
      }

      # Connection established
      $stream->timeout(0) unless $op->{type} eq 'basic';
      $stream->on(close => sub { $self->_error($id) });
      $stream->on(error => sub { $self and $self->_error($id, $_[1]) });
      $stream->on(read => sub { $self->_read($id, $_[1]) });
      $self->_connected($id)->emit(connection => $id);
    }
  );

  $self->{connections}{$id} = $op;
  $self;
}

sub _connected {
  my ($self, $id) = @_;
  my ($password) = reverse split /:/, +($self->url->userinfo // '');
  my $db = $self->url->path->[0];
  my $c = $self->{connections}{$id};

  warn "[redis:$id:connected] @{[$self->url]}\n" if DEBUG == 2;

  # NOTE: unshift() will cause AUTH to be sent before SELECT
  if (length $db) {
    $c->{skip}++;
    unshift @{ $c->{queue} }, [ SELECT => $db ];
  }
  if ($password) {
    $c->{skip}++;
    unshift @{ $c->{queue} }, [ AUTH => $password ];
  }

  $self->_dequeue($id);
}

sub _dequeue {
  my ($self, $id) = @_;
  my $c = $self->{connections}{$id};
  my $loop = $self->_loop($c->{nb});
  my $stream = $loop->stream($id) or return $self;
  my $queue = $c->{queue} ||= [];

  # Make sure connection has not been corrupted while event loop was stopped
  if (!$loop->is_running and $stream->is_readable) {
    $stream->close;
    return $self;
  }

  while (@$queue) {
    my $buf = $self->_op_to_command(shift @$queue);
    do { local $_ = $buf; s!\r\n!\\r\\n!g; warn "[redis:$id:write] ($_)\n" } if DEBUG;
    $stream->write($buf);
    last unless $c->{pipelined};
  }

  delete $c->{queue} unless @$queue;
  return $self;
}

sub _error {
  my ($self, $id, $err) = @_;
  my $c = delete $self->{connections}{$id};
  my $cb = $c->{cb};

  warn "[redis:$id:error] @{[$err // 'close']}\n" if DEBUG;

  return $self->_connect($c) if $c->{queue};
  return $self unless defined $err;
  return $self->$cb($err, []) if $cb;
  return $self->emit_safe(error => $err);
}

sub _execute {
  my ($self, $op) = @_;
  my $connections = $self->{connections} || {};
  my ($c, $id);

  $op->{n} = @{ $op->{queue} || [] };

  unless ($op->{n}) {
    Scalar::Util::weaken($self);
    my $cb = $op->{cb};
    $self->_loop($op->{nb})->timer(0 => sub { $self and $self->$cb('', []); });
    return $self;
  }

  for (keys %$connections) {
    $c = $connections->{$_};
    next if $c->{nb} ne $op->{nb};
    next if $c->{type} ne $op->{type};
    next if $c->{queue};
    $id = $_;
    last;
  }

  return $self->_connect($op) unless $id;
  $c->{$_} = $op->{$_} for keys %$op;
  return $self->_dequeue($id);
}

sub _loop {
  $_[1] ? Mojo::IOLoop->singleton : ($_[0]->{ioloop} ||= Mojo::IOLoop->new);
}

sub _op_to_command {
  my ($self, $op) = @_;
  my @data;

  for my $token (@$op) {
    $token = Mojo::Util::encode($self->encoding, $token) if $self->encoding;
    push @data, {type => '$', data => $token};
  }

  $self->protocol->encode({type => '*', data => \@data});
}

sub _read {
  my ($self, $id, $buf) = @_;
  my $protocol = $self->protocol;
  my $c = $self->{connections}{$id};
  my $event;

  do { local $_ = $buf; s!\r\n!\\r\\n!g; warn "[redis:$id:read] ($_)\n" } if DEBUG;
  $protocol->parse($buf);

  MESSAGE:
  while (my $message = $protocol->get_message) {
    my $data = $self->_reencode_message($message);

    if (ref $data eq 'SCALAR') {
      $c->{err} ||= $$data;
      if ($c->{pipelined}) {
        push @{ $c->{res} }, undef;
      }
      else {
        push @{ $c->{res} }, undef for 1..$c->{n};
        delete $c->{$_} for qw( skip queue );
        next MESSAGE;
      }
    }
    elsif (ref $data eq 'ARRAY' and $data->[0] =~ /^(p?message)$/i) {
      $event = shift @$data;
      $self->emit($event => reverse @$data);
    }
    elsif (--$c->{skip} >= 0) {
      next MESSAGE;
    }
    else {
      push @{ $c->{res} }, $data;
    }

    --$c->{n};
  }

  if ($c->{n} and $c->{queue}) {
    $self->_dequeue($id);
  }
  elsif (!$event and my $cb = delete $c->{cb}) {
    $self->$cb($c->{err} // '', delete $c->{res});
  }
}

sub _reencode_message {
  my ($self, $message) = @_;
  my ($type, $data) = @{$message}{qw( type data )};

  if ($type ne '*' and $self->encoding and $data) {
    $data = Encode::decode($self->encoding, $data);
  }

  if ($type eq '-') {
    return \ $data;
  }
  elsif ($type ne '*') {
    return $data;
  }
  else {
    return [ map { $self->_reencode_message($_); } @$data ];
  }
}

sub _subscribe {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  my ($self, @op) = @_;

  $self->_execute({
    cb => $cb,
    nb => 1,
    pipelined => 0,
    queue => [[@op]],
    type => 'pubsub',
  });
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
