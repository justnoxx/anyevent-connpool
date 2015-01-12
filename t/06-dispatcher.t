use strict;
use warnings;
use AnyEvent::ConnPool;
use Data::Dumper;

use Test::More tests => 6;

my $global_counter = 1;
my $connpool = AnyEvent::ConnPool->new(
    constructor     =>  sub {
        return bless {value => $global_counter++}, 'Foo::Bar::Baz';
    },
    size    =>  3,
    init    =>  1,
);


my $d = $connpool->dispatcher();

print "Before die: ", Dumper $d;
my $result = $d->foo("Test");

print "After die: ", Dumper $d;
is ($result, 'Test', 'Dispatcher ok');
eval {
    $d->undefined_sub();
};

ok($@, "Undefined subroutine called with exception");
$@ = '';

my $pool = undef;

# my $pool = AnyEvent::ConnPool->pool_from_dispatcher();
$pool = AnyEvent::ConnPool->pool_from_dispatcher($d);
is (ref $pool, 'AnyEvent::ConnPool', 'AnyEvent::ConnPool->pool_from_dispatcher($d)');
$pool = undef;

# my $pool = AnyEvent::ConnPool::pool_from_dispatcher();
$pool = AnyEvent::ConnPool::pool_from_dispatcher($d);
is (ref $pool, 'AnyEvent::ConnPool', 'AnyEvent::ConnPool::pool_from_dispatcher($d)');
$pool = undef;

# my $pool = $connpool->from_dispatcher;
$pool = $connpool->pool_from_dispatcher($d);
is (ref $pool, 'AnyEvent::ConnPool', '$pool->pool_from_dispatcher($d)');
$pool = undef;

eval {
    $pool = $connpool->from_dispatcher();
};
ok($@, "Fail on pool_from_dispatcher with bad params");

1;

package Foo::Bar::Baz;
use strict;
use Data::Dumper;
sub foo {
    my ($self, $param) = @_;
    print Dumper \@_;
    return $param;
}

1;

