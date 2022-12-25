use v6.d;
die 'A VM version of v2022.04 or later is required for uint bug fixes' if $*VM.version < v2022.04;
unit class Gauge:ver<0.0.5>:auth<zef:Kaiepi>:api<0> is Seq;

#|[ A lazy, non-deterministic iterator that evaluates side effects when
    skipping rather than sinking. ]
role Iterator does Iterator {
    method is-lazy(::?CLASS:_: --> True) { }

    method is-deterministic(::?CLASS:_: --> False) { }

    method skip-one(::?CLASS:_: --> True) { self.pull-one }

    method sink-all(::?CLASS:_: --> IterationEnd) { }

    method demultiplex(::?CLASS:D: uint $signals --> Seq:D) {
        gather if $signals {
            take self;
            (take self.clone) xx $signals.pred
        }
    }
}

#|[ Produces a nanosecond duration of a call to a block. ]
class It does Iterator {
    has $!block;

    submethod BUILD(::?CLASS:D: Block:D :$block! --> Nil) {
        use nqp;
        $!block := nqp::getattr(nqp::decont($block), Code, '$!do');
    }

    method block(::?CLASS:D: --> Block:D) {
        use nqp;
        nqp::getcodeobj($!block)
    }

    method pull-one(::?CLASS:_: --> uint64) {
        # XXX: A monotonic solution via Inline::Perl5 takes too long to take
        # the time, slashing the number of iterations that can be counted. A
        # NativeCall solution is apt to have the similar problems. Using &now
        # or even comparing the nqp::time to determine if a jump has occurred
        # will influence results too. Basically, if you run this during a leap
        # second or encounter any hardware errors, results will be skewed.
        use nqp;
        nqp::stmts(
          (my uint64 $begin = nqp::time()),
          nqp::call($!block),
          nqp::sub_i(nqp::time(), $begin))
    }
}
#=[ This is based off the real clock time, and isn't monotonic as a
    consequence. ]

#|[ Counts iterations over a nanosecond duration. ]
role Poller does Iterator {
    has $.seconds;
    has $!ns;
    has $!it;

    submethod BUILD(::?CLASS:D: Real:D :$seconds!, Iterator:D :$it! --> Nil) {
        $!seconds := $seconds<>;
        $!ns       = $seconds * 1_000_000_000 +^ 0;
        $!it      := $it<>;
    }

    method gc(::?CLASS:D: --> Bool:D) { ... }
}

#|[ Counts iterations over a nanosecond duration with minimal overhead, but as
    a consequence, the likelihood of results being skewed by GC. ]
class Poller::Raw does Poller {
    method gc(::?CLASS:_: --> False) { }

    method pull-one(::?CLASS:_:) {
        use nqp;
        nqp::stmts(
          (my $ns = $!ns),
          (my $n = 0),
          nqp::while(
            (($ns -= $!it.pull-one) >= 0),
            ($n++)),
          $n)
    }
}

#|[ Counts iterations over a nanosecond duration with garbage collection
    beforehand to give stable results. ]
class Poller::Collected does Poller {
    method gc(::?CLASS:_: --> True) { }

    method pull-one(::?CLASS:_:) {
        use nqp;
        nqp::stmts(
          (my $ns = $!ns),
          (my $n = 0),
          nqp::force_gc(),
          nqp::while(
            (($ns -= $!it.pull-one) >= 0),
            ($n++)),
          $n)
    }

    method demultiplex(::?CLASS:D: uint $signals --> Seq:D) {
        gather if $signals {
            # When demuxing to threaded benchmarks, only one thread should be
            # performing any preliminary global lock through GC, if at all...
            take self;
            (take Poller::Raw.new: :$!seconds, :it($!it.clone)) xx $signals.pred
        }
    }
}
#|[ This should approach producing the most ideal scenario for an iteration
    with regards to memory, but not quite manage to pull it off. ]

#|[ Sleeps a number of seconds between iterations. ]
class Throttler does Iterator {
    has num $.seconds;
    has     $!it;
    has     $!sleeps;

    submethod BUILD(::?CLASS:D: Num(Real:D) :$!seconds!, Iterator:D :$it! --> Nil) {
        $!it     := $it<>;
        $!sleeps  = False;
    }

    method pull-one(::?CLASS:_:) {
        use nqp;
        nqp::stmts(
          nqp::if(
            nqp::cas($!sleeps, False, True),
            nqp::sleep($!seconds)),
          $!it.pull-one)
    }
}

#|[ A result emitted by Gauge::Signal, paired to and keyed by its band. ]
class Packet is Pair {
    #|[ Produces a permit for a new band of packets. ]
    method permit(::?CLASS:D: --> ::?CLASS:D) {
        self.new: :key(self.key.succ), :value(self.value)
    }
    #|[ This depends on there being a cache; it plays nice with &cas. ]

    #|[ Follows through on a permit by filling a copy's value with a result. ]
    proto method sign(::?CLASS:D: $ --> ::?CLASS:D) {*}
    #=[ This should not nest; calculate offsets like you might a Test &plan. ]
    multi method sign(::?CLASS:_: $buffer) {
        self.new: :key(self.key), :value($buffer)
    }
    multi method sign(::?CLASS:_: ::?CLASS:D $packet) {
        $packet
    }
}

#|[ Jails a gauged iteration in its own thread. ]
class Signal is Thread {
    my $band is default(Packet.new: 0, 0);
    my &code := -> { send $*THREAD };

    has $.packet;
    has $!values;
    has $!taking is default(True);
    has $!result;
    has $!wanted;
    has $!marked;

    submethod BUILD(::?CLASS:D: :$packet!, :$values! --> Nil) {
        $!packet := $packet<>;
        $!values := $values<>;
        $!wanted := Semaphore.new: 0;
        $!marked := Semaphore.new: 0;
    }

    #|[ Prepares to calculate results from a gauged iteration. ]
    method new(::?CLASS:_: Iterator:D $values) {
        callwith :packet(cas $band, *.permit), :$values, :&code, :name('gauge ' ~ ⚛$band), :app_lifetime
    }

    #|[ Begins calculation of results from a gauged iteration. ]
    method run(::?CLASS:D:) {
        use nqp;
        nqp::semrelease($!wanted);
        callsame
    }

    #|[ Encodes a sequence of iterations to sample. ]
    method form(::?CLASS:_: Iterable:D $sources) {
        $sources.map({ self.new: $^it }).eager.map(*.run).cache
    }

    my method send(::?CLASS:_: --> Nil) {
        use nqp;
        nqp::while(
          nqp::atomicload($!taking),
          nqp::stmts(
            nqp::semacquire($!wanted),
            nqp::atomicstore($!result,$!values.pull-one),
            nqp::semrelease($!marked)));
    }

    #|[ Yields a result and prompts the next iteration in the background. ]
    proto method receive(::?CLASS:_:) {*}
    multi method receive(::?CLASS:U: --> IterationEnd) { }
    multi method receive(::?CLASS:D:) {
        use nqp;
        nqp::semacquire($!marked);
        my $result := nqp::atomicload($!result);
        nqp::semrelease($!wanted);
        $!packet.sign: $result
    }
}

#|[ Gathers results from multiple threads making calculations simultaneously. ]
class Multiplexer does Iterator {
    has @!signals;
    has uint $!sliced;
    has uint $!writer;
    has uint $!reader;

    submethod BUILD(::?CLASS:D: uint :$signals!, Iterator:D :$it! --> Nil) {
        @!signals := list Signal unless $signals;
        @!signals := Signal.form: $it.demultiplex: $signals unless @!signals;
        $!sliced   = $signals && $signals.pred;
    }

    method pull-one(::?CLASS:_:) {
        use nqp;
        nqp::stmts(
          (my $result := @!signals.AT-POS(($!reader .= pred) min= $!writer).receive),
          ($!writer++ unless $!reader || $!writer >= $!sliced),
          $result)
    }
}
#=[ Despite threads being instantiated in sequence, they are walked backwards. ]

#|[ If True, Gauge will perform a garbage collection before an intensive
    iteration. This allows for more stable results, thus is, by default, True
    on backends supporting garbage collection. ]
has Bool:D $.gc is default(so $*VM.name eq <moar jvm>.any);

#|[ Produces a lazy sequence of native integer durations of calls to the given
    block via Gauge::It. ]
method CALL-ME(::?CLASS:_: Block:D $block, *%attrinit --> ::?CLASS:D) {
    my $self := self.new: It.new: :$block;
    %attrinit ?? $self.clone(|%attrinit) !! $self
}

#|[ Counts iterations of the gauged block over a number of seconds via
    Gauge::Poller. ]
method poll(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    my $it := $!gc ?? Poller::Collected !! Poller::Raw;
    self.new: $it.new: :$seconds, :it(self.iterator)
}

#|[ Sleeps a number of seconds between iterations of the gauged block via
    Gauge::Throttler. ]
method throttle(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    self.new: Throttler.new: :$seconds, :it(self.iterator)
}

#|[ Demultiplexes this iterator across a number of threads, collecting results
    via Gauge::Multiplexer. ]
method demultiplex(::?CLASS:D: UInt:D $signals --> ::?CLASS:D) {
    self.new: Multiplexer.new: :$signals, :it(self.iterator)
}
