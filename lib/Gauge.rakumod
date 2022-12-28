use v6.d;
die 'A VM version of v2022.04 or later is required for uint bug fixes' if $*VM.version < v2022.04;
unit class Gauge:ver<0.0.5>:auth<zef:Kaiepi>:api<0> is Seq;

#|[ Tracks how many iterations make a cycle with which to boot or view. ]
role Curve {
    method cycle-only(::?CLASS:D: --> int) { ... }

    method skip-cyclic(::?CLASS:D: int --> True) { ... }

    method push-cyclic(::?CLASS:D: Mu, int --> True) { ... }
}

#|[ The heart of a cyclic iteration. ]
role Helix[Iterator ::T = Iterator] does T does Curve {
    method cycle-only(::?CLASS:D: --> 1) { }

    method skip-cyclic(::?CLASS:D: int $n --> True) {
        $n and self.skip-at-least: $n;
    }

    method push-cyclic(::?CLASS:D: Mu $target is raw, int $n --> True) {
        $n and self.push-exactly: $target, $n;
    }
}
#=[ This carries a static cycle count. ]

#|[ A curve layered over another in some way. ]
role Spiral[Iterator ::T = Iterator] does T does Curve {
    method skip-cyclic(::?CLASS:D: int $n is copy --> True) {
        use nqp;
        nqp::while($n,((self.skip-at-least: self.cycle-only) && $n--));
    }

    method push-cyclic(::?CLASS:D: Mu $target is raw, UInt:D $n is copy --> True) {
        use nqp;
        nqp::while($n,nqp::stmts((self.push-exactly: $target, self.cycle-only),($n--)));
    }
}
#=[ This carreis a dynamic cycle count. Pointing to another curve is OK, but
    calculations necessary to make one must be thread-safe (unlike Iterator). ]

#|[ A lazy, non-deterministic iterator that evaluates side effects when
    skipping rather than sinking. ]
role Iterator[Curve ::T] does T {
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
class It does Iterator[Helix] {
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
role Poller does Iterator[Spiral] {
    has $.seconds;
    has $!ns;
    has $!it;

    submethod BUILD(::?CLASS:D: Real:D :$seconds!, Iterator:D :$it! --> Nil) {
        $!seconds := $seconds<>;
        $!ns       = $seconds * 1_000_000_000 +^ 0;
        $!it      := $it<>;
    }

    method gc(::?CLASS:D: --> Bool:D) { ... }

    method cycle-only(::?CLASS:D: --> int) {
        $!it.cycle-only
    }
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
}
#|[ This should approach producing the most ideal scenario for an iteration
    with regards to memory, but not quite manage to pull it off. ]

#|[ Sleeps a number of seconds between iterations. ]
class Throttler does Iterator[Spiral] {
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

    method cycle-only(::?CLASS:D: --> int) {
        $!it.cycle-only
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
    proto method new(::?CLASS:_: $) {*}
    multi method new(::?CLASS:_: Gauge:D $gauge) {
        samewith $gauge.iterator
    }
    multi method new(::?CLASS:_: Iterator:D $values) {
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

    #|[ The wrapped iteration's cycle count. ]
    method cycle(::?CLASS:D: --> int) {
        $!values.cycle-only
    }
}

#|[ Gathers results from multiple threads making calculations simultaneously. ]
class Multiplexer does Iterator[Spiral] {
    has @!signals;
    has uint $!sliced;
    has uint $!writer;
    has uint $!reader;
    has $!cycles is default(0); # $!writer boxed atomically

    proto submethod BUILD(::?CLASS:D: --> Nil) {*}
    multi submethod BUILD(::?CLASS:_: uint :$signals!, Iterator:D :$it! --> Nil) {
        @!signals := list Signal unless $signals;
        @!signals := Signal.form: $it.demultiplex: $signals unless @!signals;
        $!sliced   = $signals && $signals.pred;
    }
    multi submethod BUILD(::?CLASS:_: :@gauged! --> Nil) {
        @!signals := Signal.form: @gauged;
        $!sliced   = @gauged.end if @gauged;
    }

    method pull-one(::?CLASS:_:) {
        use nqp;
        nqp::stmts(
          (my $result := @!signals.AT-POS(($!reader .= pred) min= $!writer).receive),
          ($!reader || nqp::isge_u($!writer,$!sliced) || nqp::atomicstore($!cycles,++$!writer)),
          $result)
    }

    method cycle-only(::?CLASS:D: --> int) {
        use nqp;
        # This needs to be thread-safe (unlike Iterator) because counts are
        # taken across threads. Calculation of a cycle occurs before the actual
        # cycle itself. Signals are eager and we have seq-cst memory ordering.
        @!signals.head(nqp::atomicload($!cycles).succ).map(*.cycle).sum
    }
}
#=[ Despite threads being instantiated in sequence, they are walked backwards. ]

#|[ If True, Gauge will perform a garbage collection before an intensive
    iteration. This will thrash paallel results, so don't set this by default. ]
has Bool:D $.gc is default(False);

#|[ Gauges an iteration, manually copying attributes across instances. ]
proto method new(::?CLASS:_: | --> ::?CLASS:D) {*}
multi method new(::?CLASS:U: $it, *%attrinit) {
    %attrinit ?? callwith($it) !! callwith($it).clone(|%attrinit)
}
multi method new(::?CLASS:D: $it, :$gc = $!gc, *%attrinit) {
    callwith($it).clone(:$gc, |%attrinit)
}

#|[ Produces a lazy sequence of native integer durations of calls to the given
    block via Gauge::It. ]
method CALL-ME(::?CLASS:_: Block:D $block, *%attrinit --> ::?CLASS:D) {
    self.new: It.new: :$block, |%attrinit
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

#|[ Multiplexes any nunber of gauged iterations into one, collecting results
    via Gauge::Multiplexer. ]
method multiplex(::?CLASS:_: @gauged --> ::?CLASS:D) {
    self.new: Multiplexer.new: :@gauged
}

#|[ Gauge's multiplexing operator. ]
only infix:<switch>(**@gauged) is assoc<list> is looser(&infix:<...>) is export {
    $?CLASS.multiplex: @gauged
}
#=[ This is designed to be depended on as a reduction. ]

#|[ Gauge's warmup operator. ]
proto infix:<boot>(| --> ::?CLASS:D) is assoc<right> is looser(&infix:<switch>) is export {*}
#=[ A cycle is one iteration of all available iterators. ]
multi infix:<boot>($cycles, ::?CLASS:D $gauged) {
    $gauged.new: samewith $cycles, $gauged.iterator
}
multi infix:<boot>(Int:D $cycles, Iterator:D $it) {
    $it.skip-cyclic: $cycles;
    $it
}

#|[ Gauge's view operator. ]
proto infix:<view>(|) is assoc<right> is looser(&infix:<switch>) is export {*}
#=[ If multiplexed, results are keyed by the ultimate band in a hash of arrays;
    in a single-threaded context, results are just gathered in just one array.
    As with &infix:<boot>, this operates in terms of iteration cycles. ]
multi infix:<view>(Int:D $cycles, ::?CLASS:D $gauged) {
    samewith $cycles, $gauged.iterator
}
multi infix:<view>(Int:D $cycles, Multiplexer:D $it) {
    $it.push-cyclic: my %results, $cycles;
    %results = %results.kv.map({ $^band => [ $^list<> ] })
}
multi infix:<view>(Int:D $cycles, Iterator:D $it) {
    $it.push-cyclic: my @results, $cycles;
    @results
}
