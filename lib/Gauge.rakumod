use v6.d;
die 'A VM version of v2020.04 or later is required for the nqp::time op' if $*VM.version < v2020.04;
# If False, Gauge will perform a garbage collection before an intensive
# iteration. This allows for more stable results, but these will approach, but
# never quite reach the greatest of ideal results, which should be possible to
# achieve with enough time and tinkering otherwise. This is the default on
# backends supporting garbage collection.
INIT PROCESS::<$GAUGE-RAW> := so $*VM.name eq <moar jvm>.none; # NOTE: No GC in the JS backend as of v2020.10.
unit class Gauge:ver<0.0.1>:auth<github:Kaiepi>:api<0> is Seq;

#|[ A lazy, non-deterministic iterator that evaluates side effects when
    skipping rather than sinking. ]
role Iterator does Iterator {
    method is-lazy(::?CLASS:_: --> True) { }

    method is-deterministic(::?CLASS:_: --> False) { }

    method block(::?CLASS:D: --> Block:D) { ... }

    method skip-one(::?CLASS:D: --> True) { self.pull-one }

    method sink-all(::?CLASS:D: --> IterationEnd) { }
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

    method pull-one(--> int) is raw {
        # XXX: A monotonic solution via Inline::Perl5 takes too long to take
        # the time, slashing the number of iterations that can be counted. A
        # NativeCall solution is apt to have the similar problems. Using &now
        # or even comparing the nqp::time to determine if a jump has occurred
        # will influence results too. Basically, if you run this during a leap
        # second or encounter any hardware errors, results will be skewed.
        use nqp;
        nqp::stmts(
          (my int $begin = nqp::time()),
          nqp::call($!block),
          nqp::sub_i(nqp::time(), $begin))
    }
}
#=[ This is based off the real clock time, and isn't monotonic as a
    consequence. ]

#|[ Counts iterations over a nanosecond duration. ]
role Poller does Iterator {
    has     $.seconds;
    has int $!ns;
    has     $!it;

    submethod BUILD(::?CLASS:D: Real:D :$seconds!, Iterator:D :$it! --> Nil) {
        $!seconds := $seconds<>;
        $!ns       = $seconds * 1_000_000_000 +^ 0;
        $!it      := $it<>;
    }

    method block(::?CLASS:D: --> Block:D) { $!it.block }

    method raw(::?CLASS:D: --> Bool:D) { ... }
}

#|[ Counts iterations over a nanosecond duration with garbage collection
    beforehand to give stable results. ]
class Poller::Collected does Poller {
    method raw(::?CLASS:_: --> False) { }

    method pull-one is raw {
        use nqp;
        nqp::stmts(
          (my int $ns = $!ns),
          (my $n = 0),
          nqp::force_gc(),
          nqp::while(
            nqp::isge_i(($ns = nqp::sub_i($ns, $!it.pull-one)), 0),
            ($n++)),
          nqp::decont($n))
    }
}
#|[ This should approach producing the most ideal scenario for an iteration
    with regards to memory, but not quite manage to pull it off. ]

#|[ Counts iterations over a nanosecond duration with minimal overhead, but as
    a consequence, the likelihood of results being skewed by GC. ]
class Poller::Raw does Poller {
    method raw(::?CLASS:_: --> True) { }

    method pull-one is raw {
        use nqp;
        nqp::stmts(
          (my int $ns = $!ns),
          (my $n = 0),
          nqp::while(
            nqp::isge_i(($ns = nqp::sub_i($ns, $!it.pull-one)), 0),
            ($n++)),
          nqp::decont($n))
    }
}
#=[ With enough time and tinkering, this is capable of producing a more
    idealistic iteration count when uninterrupted. ]

#|[ Sleeps a number of seconds between iterations. ]
class Throttler does Iterator {
    has num $.seconds;
    has     $!it;
    has     $!sleeps;

    submethod BUILD(::?CLASS:D: Num(Real:D) :$!seconds!, Iterator:D :$it! --> Nil) {
        $!it     := $it<>;
        $!sleeps  = False;
    }

    method block(::?CLASS:D: --> Block:D) { $!it.block }

    method pull-one is raw {
        use nqp;
        nqp::stmts(
          nqp::if(
            nqp::cas($!sleeps, False, True),
            nqp::sleep($!seconds)),
          $!it.pull-one)
    }
}

#|[ Produces a lazy sequence of native integer durations of calls to the given
    block via Gauge::It. ]
method CALL-ME(::?CLASS:_: Block:D $block --> ::?CLASS:D) {
    self.new: It.new: :$block
}

#|[ Counts iterations of the gauged block over a number of seconds via
    Gauge::Poller. ]
method poll(::?CLASS:D: Real:D $seconds, Poller:_ :$by = $*GAUGE-RAW ?? Poller::Raw !! Poller::Collected --> ::?CLASS:D) {
    self.new: $by.new: :$seconds, :it(self.iterator)
}

#|[ Sleeps a number of seconds between iterations of the gauged block via
    Gauge::Throttler. ]
method throttle(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    self.new: Throttler.new: :$seconds, :it(self.iterator)
}
