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

  # Will die() as soon as possible on error.
  # On success: @res = ("OK", "42", "OK");
  @res = $redis->set(foo => "42")->get("foo")->set(bar => 123)->execute;

  # Might die() too late, because of pipelined() will cause data to be sent to
  # the redis server without waiting for response.
  # On success: @res = ("OK", "42", "OK");
  @res = $redis->pipelined->set(foo => "42")->get("foo")->set(bar => 123)->execute;

=head2 Non-blocking

  Mojo::IOLoop->delay(
    sub {
      my ($delay) = @_;
      # Will not run "GET foo" unless ping() was successful
      # Use pipelined() before ping() if you want all commands to run even
      # if one operation fail.
      $redis->ping->get("foo")->execute($delay->begin);
    },
    sub {
      my ($delay, $err, $res) = @_;
      # On error: $err is set to a string
      # NOTE: $err might be set on partial success, when using pipelined()
      # On success: $res = [ "PONG", "42" ];
    },
  );

=head2 Pub/sub

L<Mojo::Redis2> can L</subscribe> and re-use the same object to C<publish> or
run other Redis commands, since it can keep track of multiple connections to
the same Redis server.

  my $id;

  $self->on(message => sub {
    my ($self, $message, $channel) = @_;

    $self->unsubscribe($id) if $message =~ /KEEP OUT/;
  });

  $id = $self->subscribe("some:channel" => sub {
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

=head2 close

  $self->on(close => sub { my ($self, $id) = @_; });

Emitted when a connection close.

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

=head2 blpop

  $res = $self->blpop(@keys);
  $self = $self->blpop(@keys => sub {
            my ($self, $err, $res) = @_;
          });

The blocking version will hang until one of the keys has data.

The non-blocking version will make a new connection to the Redis server
which allow C<$self> to issue other commands.

=head2 brpop

  $res = $self->brpop(@keys);
  $self = $self->brpop(@keys => sub {
            my ($self, $err, $res) = @_;
          });

The blocking version will hang until one of the keys has data.

The non-blocking version will make a new connection to the Redis server
which allow C<$self> to issue other commands.

=head2 brpoplpush

  $res = $self->brpoplpush($source => $destination);
  $self = $self->brpoplpush($source => $destination => sub {
            my ($self, $err, $res) = @_;
          });

The blocking version will hang until one of the keys has data.

The non-blocking version will make a new connection to the Redis server
which allow C<$self> to issue other commands.

=head2 execute

  @res = $self->execute;
  $self = $self->execute(sub {
            my ($self, $err, $res) = @_;
          });

Will send the L<prepared|/prepare> commands to the Redis server.
The callback will receive L<$err|/Error Handling> and C<$res>. C<$res>
is an array-ref with one list-item per L<prepared|/prepare> redis command.

C<$res> will be returned as a list when called in blocking context.

=cut

sub execute {
  my ($self, $cb) = @_;
  my ($err, $res);

  $self->_cleanup unless ($self->{pid} //= $$) eq $$; # TODO: Fork safety
  $self->_execute({
    cb => $cb || sub { shift->_loop(0)->stop; ($err, $res) = @_; },
    nb => $cb ? 1 : 0,
    pipelined => delete $self->{pipelined} || 0,
    queue => delete $self->{queue} || [],
    type => 'basic',
  });

  return $self if $cb;
  $self->_loop(0)->start;
  die $err if $err;
  return @$res;
}

=head2 pipelined

  $self = $self->pipelined;

Will mark L<prepared|/prepare> operations to be sent to the server
as soon as possible.

=cut

sub pipelined {
  $_[0]->{pipelined} = $_[1] // 1;
  $_[0];
}

=head2 prepare

  $self = $self->prepare($redis_method => @redis_args);

Used to prepare commands for L</execute>. Example:

  $self->prepare(GET => "foo");

There are also shortcuts for most of the C<$redis_method>. Example:

  $self->get("foo");

List of Redis methods available on C<$self>:

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

=cut

sub prepare {
  my ($self, @op) = @_;
  push @{ $self->{queue} }, [@op];
  return $self;
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

=head2 unsubscribe

  $self->unsubscribe($id);
  $self->unsubscribe($event_name);
  $self->unsubscribe($event_name => $cb);

Same as L<Mojo::EventEmitter/unsubscribe>, but can also stop a pub/sub
subscription based on an C<$id>.

=cut

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

sub _cleanup {
  # TODO
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
  my $queue = $self->{connections}{$id}{queue} ||= [];

  # Make sure connection has not been corrupted while event loop was stopped
  if (!$loop->is_running and $stream->is_readable) {
    $stream->close;
    return $self;
  }

  while (@$queue) {
    my $buf = $self->_op_to_command(shift @$queue);
    do { local $_ = $buf; s!\r\n!\\r\\n!g; warn "[redis:$id:write] ($_)\n" } if DEBUG;
    $stream->write($buf);
    last unless $self->{pipelined};
  }

  delete $c->{queue} unless @$queue;
  return $self;
}

sub _error {
  my ($self, $id, $err) = @_;
  my $c = delete $self->{connections}{$id};
  my $cb = $c->{cb};

  warn "[redis:$id:error] $err\n" if DEBUG;

  return $self->_connect($c) if $c->{queue};
  return $self->$cb($err, []) if $cb;
  return $self->emit_safe(error => $err || 'Premature connection close');
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
  my $err = '';

  do { local $_ = $buf; s!\r\n!\\r\\n!g; warn "[redis:$id:read] ($_)\n" } if DEBUG;
  $protocol->parse($buf);

  while (my $message = $protocol->get_message) {
    my ($type, $data) = $self->_reencode_message($message);
    $err ||= $data if $type eq 'error';
    next if --$c->{skip} >= 0;
    --$c->{n};
    push @{ $c->{res} }, $type eq 'error' ? undef : $data;
  }

  if ($c->{n}) {
    $self->_dequeue($id);
  }
  else {
    my $cb = $c->{cb};
    $self->$cb($err, delete $c->{res});
  }
}

sub _reencode_message {
  my ($self, $message) = @_;
  my ($type, $data) = @{$message}{qw( type data )};

  if ($type ne '*' and $self->encoding and $data) {
    $data = Encode::decode($self->encoding, $data);
  }

  if ($type eq '-') {
    return error => $data;
  }
  elsif ($type ne '*') {
    return data => $data;
  }
  else {
    return data => [ map { $self->_reencode_message($_); } @$data ];
  }
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
