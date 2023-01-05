use v6.d;
die 'A VM version of v2022.04 or later is required for uint bug fixes' if $*VM.version < v2022.04;
unit class Gauge:ver<0.0.5>:auth<zef:Kaiepi>:api<0> is Seq;

#|[ A lazy, non-deterministic iterator that evaluates side effects when
    skipping rather than sinking. ]
role Iterator does Iterator {
    method is-lazy(::?CLASS:_: --> True) { }

    method is-deterministic(::?CLASS:_: --> False) { }

    method time-one(::?CLASS:_:) { ... }

    method skip-one(::?CLASS:_:) { ... }

    method sink-all(::?CLASS:_:) { ... }
}

#|[ Produces a nanosecond duration of a call to a block. ]
class It does Iterator {
    has $!block;

    submethod BUILD(::?CLASS:D: Block:D :$block! --> Nil) {
        use nqp;
        $!block := nqp::getattr(nqp::decont($block), Code, '$!do');
    }

    method time-one(::?CLASS:D: --> uint64) {
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

    method pull-one(::?CLASS:D: --> uint64) {
        self.time-one
    }

    method skip-one(::?CLASS:D: --> True) {
        self.pull-one # boop any optimizers
    }

    method sink-all(::?CLASS:D: --> IterationEnd) { }
}
#=[ This is based off the real clock time, and isn't monotonic as a
    consequence. ]

#|[ Counts iterations over a nanosecond duration. ]
class Poller does Iterator {
    has $!ns;
    has $!it;

    submethod BUILD(::?CLASS:D: Real:D :$seconds!, Iterator:D :$it! --> Nil) {
        $!ns  = $seconds * 1_000_000_000 +^ 0;
        $!it := $it<>;
    }

    method time-one(::?CLASS:D:) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          nqp::repeat_while(($ns < $!ns), ($ns += $!it.time-one)),
          $ns)
    }

    method pull-one(::?CLASS:D:) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          (my $n is default(0)),
          nqp::while((($ns += $!it.time-one) < $!ns), ($n++)),
          $n)
    }

    method skip-one(::?CLASS:D: --> True) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          nqp::repeat_while(($ns < $!ns), ($ns += $!it.time-one)))
    }

    method sink-all(::?CLASS:D:) {
        $!it.sink-all
    }
}

#|[ Sleeps a number of seconds between iterations. ]
class Throttler does Iterator {
    has num $!seconds;
    has $!it;
    has $!sleeps is default(False);

    submethod BUILD(::?CLASS:D: Num(Real:D) :$!seconds!, Iterator:D :$it! --> Nil) {
        $!it := $it<>;
    }

    method time-one(::?CLASS:D:) {
        use nqp;
        (nqp::cas($!sleeps, False, True) && clock $!seconds) + $!it.time-one
    }

    method pull-one(::?CLASS:D:) {
        use nqp;
        (nqp::cas($!sleeps, False, True) && block $!seconds) || $!it.pull-one
    }

    method skip-one(::?CLASS:D:) {
        use nqp;
        (nqp::cas($!sleeps, False, True) && block $!seconds) || $!it.skip-one
    }

    method sink-all(::?CLASS:D:) {
        $!it.sink-all # just do it
    }

    sub block(num $seconds --> False) is pure {
        use nqp;
        nqp::sleep($seconds)
    }

    sub clock(num $seconds --> uint64) is pure {
        use nqp;
        nqp::stmts(
          (my uint64 $ns = nqp::time()),
          nqp::sleep($seconds),
          nqp::sub_i(nqp::time(), $ns))
    }
}

#|[ Produces a lazy sequence of uint64 durations of calls to a block via
    Gauge::It. ]
method CALL-ME(::?CLASS:_: Block:D $block --> ::?CLASS:D) {
    self.new: It.new: :$block
}

#|[ Counts iterations of the gauged block over a number of seconds via
    Gauge::Poller. ]
method poll(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    self.new: Poller.new: :$seconds, :it(self.iterator)
}

#|[ Sleeps a number of seconds between iterations of the gauged block via
    Gauge::Throttler. ]
method throttle(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    self.new: Throttler.new: :$seconds, :it(self.iterator)
}
