=head1 NAME

AnyEvent::ConnPool

=head1 DESCRIPTION

Simple connections pool designed for asynchronous connections

=head1 METHODS

=over

=cut

package AnyEvent::ConnPool;
use strict;
use warnings;

use Data::Dumper;
use AnyEvent;
use Carp;

our $VERSION = 0.08;

my $PID;

BEGIN {
    $PID = $$;
}


=item B<new>

Returns new pool object

    AnyEvent::ConnPool->new(
        constructor =>  sub {
            return generate_connection();
        },
        check       =>  {
            cb          =>  sub {
                my $connection = shift;
                ...
                if ($connection->conn()->ping()) {
                    return 1;
                }
                return 0;
            },
            interval    =>  10,
        },
        size        =>  5,
        init        =>  1,
    );


constructor => subroutine, which generates connection for pool.

check => pingers, allows to specify methods and interval for connection state validation.
check->{cb} => callback, used for ping connection. You should implement this logic by yourself.
If you need reconnect, you can just call

    $connection->reconnect();

check->{interval} => interval for the callback.

size => how many connections should be created on pool initialization.

init => initialize connections on pool construction.

=cut

sub new {
    my ($class, %opts) = @_;

    my $self = {
        constructor     =>  sub {1;},
        _payload        =>  [],
        index           =>  0,
        init            =>  0,
        count           =>  0,
    };

    if (!$opts{constructor}) {
        croak "Missing mandatory param constructor.";
    }
    if (ref $opts{constructor} ne 'CODE') {
        croak "Constructor should be a code reference.";
    }
    
    $self->{constructor} = $opts{constructor};

    if ($opts{check}) {
        if (ref $opts{check} ne 'HASH') {
            croak "Check param should be a hash reference.";
        }
        if (!$opts{check}->{cb}) {
            croak 'Missing cb param.';
        }
        
        if (ref $opts{check}->{cb} ne 'CODE') {
            croak 'Cb param should be a code reference.';
        }
        if (!$opts{check}->{interval}) {
            croak 'Missing interval param.';
        }
        # TODO: Add interval parameter validation
        
        $self->{check} = $opts{check};
    }

    if ($opts{size}) {
        #TODO: add validation for size

        $self->{size} = $opts{size};
    }

    bless $self, $class;

    if ($opts{init}) {
        $self->init();
    }

    return $self;
}


=item B<init>

Initializes pool.

=cut

sub init {
    my ($self, $conn_count) = @_;
    
    if ($self->{init}) {
        croak "Can't initialize already initilized pool.";
    }
    
    $conn_count ||= delete $self->{size};

    unless ($conn_count) {
        croak "Can't initilize empty pool";
    }
    
    for (1 .. $conn_count) {
        $self->add();
    }
    
    if ($self->{check}) {
        my $guard; $guard = AnyEvent->timer (
            after       =>  $self->{check}->{interval},
            interval    =>  $self->{check}->{interval},
            cb          =>  sub {
                my $temp_guard = $guard;
                for (my $i = 0; $i < $self->{count}; $i++) {
                    my $conn = $self->{_payload}->[$i];
                    eval {
                        $self->{check}->{cb}->($conn);
                        1;
                    } or do {
                        carp "Error occured: $@";
                    };
                }
            },
        );
    }

    $self->{init} = 1;
    return 1;
}


=item B<add>

Adds connection to the pool.

=cut

sub add {
    my ($self, $count) = @_;
    
    # TODO: add count support
    my $conn = $self->{constructor}->();
    my $unit = AnyEvent::ConnPool::Unit->new($conn,
        index       =>  $self->{count},
        constructor =>  $self->{constructor},
    );

    $self->_add_object_raw($unit);
}


=item B<get>

Returns AnyEvent::ConnPool::Unit object from the pool.

    my $unit = $pool->get();
    my $connection = $unit->conn();

=cut

sub get {
    my ($self, $index) = @_;
    
    if (defined $index) {
        return $self->{_payload}->[$index];
    }

    if ($self->{index} + 1 > $self->{count}) {
        $self->{index} = 0;
    }

    my $retval = $self->{_payload}->[$self->{index}];
    
    if ($retval->locked()) {
        $self->{locked}->{$self->{index}} = 1;
        $retval = $self->get_free_connection($self->{index});
    }
    else {
        delete $self->{locked}->{$self->{index}};
    }

    if (wantarray) {
        $self->{index}++;
        return ($index, $retval);
    }
    else {
        $self->{index}++;
        return $retval;
    }
}


sub grow {
    my ($self, $count) = @_;

    $count ||= 1;
    for (1 .. $count) {
        $self->add();
    }
    return 1;
}


sub shrink {
    my ($self, $count) = @_;

    $count ||= 1;
    for (1 .. $count) {
        pop @{$self->{_payload}};
    }
    return 1;
}


# utility functions

sub get_free_connection {
    my ($self, $desired_index) = @_;
    
    my $retval = undef;
    my @balanced_array = $self->balance_array($desired_index);

    for my $i (@balanced_array) {
        my $conn = $self->{_payload}->[$i];
        unless ($conn->locked) {
            $retval = $conn;
            $self->{index} = $i;
            last;
        }
    }
    return $retval;
    
}


sub balance_array {
    my ($self, $index) = @_;

    my $count = $self->{count};
    $index++;
    $count--;

    if ($index == 0 || $index >= $count) {
        return (0 .. $count);
    }

    return (($index .. $count), 0 .. $index - 1);
}


sub _add_object_raw {
    my ($self, $object, $position) = @_;
    
    if (defined $position) {
        $self->{_payload}->[$self->{index}] = $object;
    }
    else {
        push @{$self->{_payload}}, $object;
    }

    $self->{count} = scalar @{$self->{_payload}};
    return 1;
}


=back
=cut

1;

package AnyEvent::ConnPool::Unit;
=head1 NAME

AnyEvent::ConnPool::Unit

=head1 DESCRIPTION

Connection unit. Just wrapper around user-specified connection.
Required for transactions support.

=head1 METHODS

=over

=cut

use strict;
use warnings;

sub new {
    my ($class, $object, %opts) = @_;

    my ($index, $constructor) = ($opts{index}, $opts{constructor});

    my $unit = {
        _conn           =>  $object,
        _locked         =>  0,
        _index          =>  $index,
        _constructor    =>  $constructor,
    };

    bless $unit, $class;
    return $unit;
}

=item B<conn>

Returns connection from unit object.

=cut

sub conn {
    my $self = shift;
    return $self->{_conn};
}


=item B<lock>

Locks current connection. After that connection shouldn't be used in balancing mechanism and never will be
returned from pool. To unlock connection you should use unlock method.

    $connection->lock();

=cut

sub lock {
    my ($self) = @_;

    $self->{_locked} = 1;
    return 1;
}


=item B<unlock>

Unlocks connection and returns it to the balancing scheme. 

    $connection->unlock();

=cut

sub unlock {
    my ($self) = @_;

    delete $self->{_locked};
    return 1;
}


=item B<locked>

Returns true if connection is locked.

    if ($connection->locked()) {
        ...
    }

=cut

sub locked {
    my ($self) = @_;
    
    return $self->{_locked};
}


sub index {
    my ($self) = @_;
    return $self->{_index};
}


sub reconnect {
    my ($self) = @_;

    if ($self->{_constructor}) {
        $self->{_conn} = $self->{_constructor}->();
    }
    return 1;
}
=back
=cut

1;

