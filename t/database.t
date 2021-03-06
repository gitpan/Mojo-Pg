use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mojo::IOLoop;
use Mojo::JSON 'true';
use Mojo::Pg;

# Defaults
my $pg = Mojo::Pg->new;
is $pg->dsn,      'dbi:Pg:', 'right data source';
is $pg->username, '',        'no username';
is $pg->password, '',        'no password';
is_deeply $pg->options,
  {AutoCommit => 1, PrintError => 0, RaiseError => 1, pg_server_prepare => 0},
  'right options';

# Minimal connection string with database
$pg = Mojo::Pg->new('postgresql:///test1');
is $pg->dsn,      'dbi:Pg:dbname=test1', 'right data source';
is $pg->username, '',                    'no username';
is $pg->password, '',                    'no password';
is_deeply $pg->options,
  {AutoCommit => 1, PrintError => 0, RaiseError => 1, pg_server_prepare => 0},
  'right options';

# Minimal connection string with service and option
$pg = Mojo::Pg->new('postgresql://?service=foo&PrintError=1');
is $pg->dsn,      'dbi:Pg:service=foo', 'right data source';
is $pg->username, '',                   'no username';
is $pg->password, '',                   'no password';
is_deeply $pg->options,
  {AutoCommit => 1, PrintError => 1, RaiseError => 1, pg_server_prepare => 0},
  'right options';

# Connection string with host and port
$pg = Mojo::Pg->new('postgresql://127.0.0.1:8080/test2');
is $pg->dsn, 'dbi:Pg:dbname=test2;host=127.0.0.1;port=8080',
  'right data source';
is $pg->username, '', 'no username';
is $pg->password, '', 'no password';
is_deeply $pg->options,
  {AutoCommit => 1, PrintError => 0, RaiseError => 1, pg_server_prepare => 0},
  'right options';

# Connection string username but without host
$pg = Mojo::Pg->new('postgresql://postgres@/test3');
is $pg->dsn,      'dbi:Pg:dbname=test3', 'right data source';
is $pg->username, 'postgres',            'right username';
is $pg->password, '',                    'no password';
is_deeply $pg->options,
  {AutoCommit => 1, PrintError => 0, RaiseError => 1, pg_server_prepare => 0},
  'right options';

# Connection string with unix domain socket and options
$pg = Mojo::Pg->new(
  'postgresql://x1:y2@%2ftmp%2fpg.sock/test4?PrintError=1&RaiseError=0');
is $pg->dsn,      'dbi:Pg:dbname=test4;host=/tmp/pg.sock', 'right data source';
is $pg->username, 'x1',                                    'right username';
is $pg->password, 'y2',                                    'right password';
is_deeply $pg->options,
  {AutoCommit => 1, PrintError => 1, RaiseError => 0, pg_server_prepare => 0},
  'right options';

# Connection string with lots of zeros
$pg = Mojo::Pg->new('postgresql://0:0@/0?RaiseError=0');
is $pg->dsn,      'dbi:Pg:dbname=0', 'right data source';
is $pg->username, '0',               'right username';
is $pg->password, '0',               'right password';
is_deeply $pg->options,
  {AutoCommit => 1, PrintError => 0, RaiseError => 0, pg_server_prepare => 0},
  'right options';

# Invalid connection string
eval { Mojo::Pg->new('http://localhost:3000/test') };
like $@, qr/Invalid PostgreSQL connection string/, 'right error';

$pg = Mojo::Pg->new($ENV{TEST_ONLINE});
ok $pg->db->ping, 'connected';

# Blocking select
is_deeply $pg->db->query('select 1 as one, 2 as two, 3 as three')->hash,
  {one => 1, two => 2, three => 3}, 'right structure';

# Non-blocking select
my ($fail, $result);
my $db = $pg->db;
is $db->backlog, 0, 'no operations waiting';
$db->query(
  'select 1 as one, 2 as two, 3 as three' => sub {
    my ($db, $err, $results) = @_;
    $fail   = $err;
    $result = $results->hash;
    Mojo::IOLoop->stop;
  }
);
is $db->backlog, 1, 'one operation waiting';
Mojo::IOLoop->start;
is $db->backlog, 0, 'no operations waiting';
ok !$fail, 'no error';
is_deeply $result, {one => 1, two => 2, three => 3}, 'right structure';

# Concurrent non-blocking selects
($fail, $result) = ();
Mojo::IOLoop->delay(
  sub {
    my $delay = shift;
    my $db    = $pg->db;
    $db->query('select 1 as one' => $delay->begin);
    $db->query('select 2 as two' => $delay->begin);
    $db->query('select 2 as two' => $delay->begin);
  },
  sub {
    my ($delay, $err_one, $one, $err_two, $two, $err_again, $again) = @_;
    $fail = $err_one || $err_two || $err_again;
    $result
      = [$one->hashes->first, $two->hashes->first, $again->hashes->first];
  }
)->wait;
ok !$fail, 'no error';
is_deeply $result, [{one => 1}, {two => 2}, {two => 2}], 'right structure';

# Connection cache
is $pg->max_connections, 5, 'right default';
my @dbhs = map { $_->dbh } $pg->db, $pg->db, $pg->db, $pg->db, $pg->db;
is_deeply \@dbhs,
  [map { $_->dbh } $pg->db, $pg->db, $pg->db, $pg->db, $pg->db],
  'same database handles';
@dbhs = ();
my $dbh = $pg->max_connections(1)->db->dbh;
is $pg->db->dbh, $dbh, 'same database handle';
isnt $pg->db->dbh, $pg->db->dbh, 'different database handles';
is $pg->db->dbh, $dbh, 'different database handles';
$dbh = $pg->db->dbh;
is $pg->db->dbh, $dbh, 'same database handle';
$pg->db->disconnect;
isnt $pg->db->dbh, $dbh, 'different database handles';

# Dollar only
$db = $pg->db;
is $db->dollar_only->query('select $1 as test', 23)->hash->{test}, 23,
  'right result';
eval { $db->dollar_only->query('select ? as test', 23) };
like $@, qr/called with 1 bind variables when 0 are needed/, 'right error';
is $db->query('select ? as test', 23)->hash->{test}, 23, 'right result';

# JSON
$db = $pg->db;
is_deeply $db->query('select ?::json as foo', {json => {bar => 'baz'}})
  ->expand->hash, {foo => {bar => 'baz'}}, 'right structure';
is_deeply $db->query('select ?::json as foo', {json => {bar => 'baz'}})
  ->expand->array, [{bar => 'baz'}], 'right structure';
is_deeply $db->query('select ?::json as foo', {json => {bar => 'baz'}})
  ->expand->hashes->first, {foo => {bar => 'baz'}}, 'right structure';
is_deeply $db->query('select ?::json as foo', {json => {bar => 'baz'}})
  ->expand->arrays->first, [{bar => 'baz'}], 'right structure';
is_deeply $db->query('select ?::json as foo', {json => {bar => 'baz'}})->hash,
  {foo => '{"bar":"baz"}'}, 'right structure';
is_deeply $db->query('select ?::json as foo', {json => \1})
  ->expand->hashes->first, {foo => true}, 'right structure';
is_deeply $db->query('select ?::json as foo', undef)->expand->hash,
  {foo => undef}, 'right structure';
is_deeply $db->query('select ?::json as foo', undef)->expand->array, [undef],
  'right structure';
my $results = $db->query('select ?::json', undef);
is_deeply $results->expand->array, [undef], 'right structure';
is_deeply $results->expand->array, undef, 'no more results';

# Fork safety
$dbh = $pg->db->dbh;
my ($connections, $current) = @_;
$pg->on(
  connection => sub {
    my ($pg, $dbh) = @_;
    $connections++;
    $current = $dbh;
  }
);
is $pg->db->dbh, $dbh, 'same database handle';
ok !$connections, 'no new connections';
{
  local $$ = -23;
  isnt $pg->db->dbh, $dbh,     'different database handles';
  is $pg->db->dbh,   $current, 'same database handle';
  is $connections, 1, 'one new connection';
};
$pg->unsubscribe('connection');

# Notifications
$db = $pg->db;
ok !$db->is_listening, 'not listening';
ok $db->listen('foo')->is_listening, 'listening';
my $db2 = $pg->db->listen('foo');
my @notifications;
Mojo::IOLoop->delay(
  sub {
    my $delay = shift;
    $db->once(notification => $delay->begin);
    $db2->once(notification => $delay->begin);
    Mojo::IOLoop->next_tick(sub { $db2->notify('foo', 'bar') });
  },
  sub {
    my ($delay, $name, $pid, $payload, $name2, $pid2, $payload2) = @_;
    push @notifications, [$name, $pid, $payload], [$name2, $pid2, $payload2];
    $db->once(notification => $delay->begin);
    $db2->unlisten('foo');
    Mojo::IOLoop->next_tick(sub { $pg->db->notify('foo') });
  },
  sub {
    my ($delay, $name, $pid, $payload) = @_;
    push @notifications, [$name, $pid, $payload];
    $db2->listen('bar')->once(notification => $delay->begin);
    Mojo::IOLoop->next_tick(sub { $db2->do("notify bar, 'baz'") });
  },
  sub {
    my ($delay, $name, $pid, $payload) = @_;
    push @notifications, [$name, $pid, $payload];
    $db2->once(notification => $delay->begin);
    my $tx = $db2->begin;
    Mojo::IOLoop->next_tick(
      sub {
        $db2->notify('bar', 'yada');
        $tx->commit;
      }
    );
  },
  sub {
    my ($delay, $name, $pid, $payload) = @_;
    push @notifications, [$name, $pid, $payload];
  }
)->wait;
ok !$db->unlisten('foo')->is_listening, 'not listening';
ok !$db2->unlisten('*')->is_listening,  'not listening';
is $notifications[0][0], 'foo',  'right channel name';
ok $notifications[0][1], 'has process id';
is $notifications[0][2], 'bar',  'right payload';
is $notifications[1][0], 'foo',  'right channel name';
ok $notifications[1][1], 'has process id';
is $notifications[1][2], 'bar',  'right payload';
is $notifications[2][0], 'foo',  'right channel name';
ok $notifications[2][1], 'has process id';
is $notifications[2][2], '',     'no payload';
is $notifications[3][0], 'bar',  'right channel name';
ok $notifications[3][1], 'has process id';
is $notifications[3][2], 'baz',  'no payload';
is $notifications[4][0], 'bar',  'right channel name';
ok $notifications[4][1], 'has process id';
is $notifications[4][2], 'yada', 'no payload';
is $notifications[5], undef, 'no more notifications';

# Stop listening for all notifications
ok !$db->is_listening, 'not listening';
ok $db->listen('foo')->listen('bar')->unlisten('bar')->is_listening,
  'listening';
ok !$db->unlisten('*')->is_listening, 'not listening';

# Connection close while listening for notifications
{
  ok $db->listen('foo')->is_listening, 'listening';
  my $close = 0;
  $db->on(close => sub { $close++ });
  local $db->dbh->{Warn} = 0;
  $pg->db->query('select pg_terminate_backend(?)', $db->pid);
  Mojo::IOLoop->start;
  is $close, 1, 'close event has been emitted once';
};

# Blocking error
eval { $pg->db->query('does_not_exist') };
like $@, qr/does_not_exist/, 'right error';

# Non-blocking error
($fail, $result) = ();
$pg->db->query(
  'does_not_exist' => sub {
    my ($db, $err, $results) = @_;
    $fail   = $err;
    $result = $results;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
like $fail, qr/does_not_exist/, 'right error';
is $result->sth->errstr, $fail, 'same error';

done_testing();
