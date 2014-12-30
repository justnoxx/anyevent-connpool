use strict;
use warnings;
use AnyEvent::ConnPool;
use Test::More tests => 2;

my $global_counter = 1;
my $connpool = AnyEvent::ConnPool->new(
    constructor     =>  sub {
        return bless {value => $global_counter++}, 'Foo::Bar::Baz';
    },
    size    =>  3,
    init    =>  1,
);

my $d = $connpool->dispatcher();

my $result = $d->foo("Test");

is ($result, 'Test', 'Dispatcher ok');

eval {
    $d->undefined_sub();
};

ok($@, "Undefined subroutine called with exception");

1;

package Foo::Bar::Baz;
use strict;

sub foo {
    my ($self, $param) = @_;
    return $param;
}

1;

