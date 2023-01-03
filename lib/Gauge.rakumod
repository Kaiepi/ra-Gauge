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

    method block(::?CLASS:_: --> Block:D) { ... }

    method gc(::?CLASS:_: --> Bool:D) { ... }
}

#|[ Produces a nanosecond duration of a call to a block. ]
class It does Iterator {
    has $!block;
    has $.gc;

    submethod BUILD(::?CLASS:D: Block:D :$block!, Bool:D :$gc = False --> Nil) {
        use nqp;
        $!block := nqp::getattr(nqp::decont($block), Code, '$!do');
        $!gc    := $gc<>;
    }

    method block(::?CLASS:D: --> Block:D) {
        use nqp;
        nqp::getcodeobj($!block)
    }

    method pull-one(::?CLASS:D: --> uint64) {
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

    method block(::?CLASS:D: --> Block:D) { $!it.block }
}

#|[ Counts iterations over a nanosecond duration with minimal overhead, but as
    a consequence, the likelihood of results being skewed by GC. ]
class Poller::Raw does Poller {
    method gc(::?CLASS:_: --> False) { }

    method pull-one(::?CLASS:D:) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          (my $n is default(0)),
          nqp::while((($ns += $!it.pull-one) < $!ns), ($n++)),
          $n)
    }
}

#|[ Counts iterations over a nanosecond duration with garbage collection
    beforehand to give stable results. ]
class Poller::Collected does Poller {
    method gc(::?CLASS:_: --> True) { }

    method pull-one(::?CLASS:D:) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          (my $n is default(0)),
          nqp::force_gc(),
          nqp::while((($ns += $!it.pull-one) < $!ns), ($n++)),
          $n)
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

    method block(::?CLASS:D: --> Block:D) { $!it.block }

    method gc(::?CLASS:D: --> Bool:D) { $!it.gc }

    method pull-one(::?CLASS:D:) {
        use nqp;
        nqp::stmts(
          nqp::if(
            nqp::cas($!sleeps, False, True),
            nqp::sleep($!seconds)),
          $!it.pull-one)
    }
}

#|[ Produces a lazy sequence of uint64 durations of calls to a block via
    Gauge::It. ]
method CALL-ME(::?CLASS:_: Block:D $block, Bool:D :$gc = False --> ::?CLASS:D) {
    self.new: It.new: :$block, :$gc
}
#=[ This may be configured to perform a GC before intensive operations (i.e.
    poll as depended on by Gauge). In a relay, this can pause mid-iteration! ]

#|[ Counts iterations of the gauged block over a number of seconds via
    Gauge::Poller. ]
method poll(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    my $it := self.iterator;
    my $ty := $it.gc ?? Poller::Collected !! Poller::Raw;
    self.new: $ty.new: :$seconds, :$it
}

#|[ Sleeps a number of seconds between iterations of the gauged block via
    Gauge::Throttler. ]
method throttle(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    self.new: Throttler.new: :$seconds, :it(self.iterator)
}
