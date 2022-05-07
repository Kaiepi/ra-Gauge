use v6.d;
die 'A VM version of v2022.04 or later is required for uint bug fixes' if $*VM.version < v2022.04;
unit class Gauge:ver<0.0.3>:auth<zef:Kaiepi>:api<0> is Seq;

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

    method pull-one(--> uint64) {
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
    has      $.seconds;
    has uint $!ns;
    has      $!it;

    submethod BUILD(::?CLASS:D: Real:D :$seconds!, Iterator:D :$it! --> Nil) {
        $!seconds := $seconds<>;
        $!ns       = $seconds * 1_000_000_000 +^ 0;
        $!it      := $it<>;
    }

    method block(::?CLASS:D: --> Block:D) { $!it.block }

    method gc(::?CLASS:D: --> Bool:D) { ... }
}

#|[ Counts iterations over a nanosecond duration with garbage collection
    beforehand to give stable results. ]
class Poller::Collected does Poller {
    method gc(::?CLASS:_: --> True) { }

    method pull-one {
        use nqp;
        nqp::stmts(
          (my uint $ns = $!ns),
          (my $n = 0),
          nqp::force_gc(),
          nqp::while(
            nqp::isge_i(($ns = nqp::sub_i($ns, $!it.pull-one)), 0),
            ($n++)),
          $n)
    }
}
#|[ This should approach producing the most ideal scenario for an iteration
    with regards to memory, but not quite manage to pull it off. ]

#|[ Counts iterations over a nanosecond duration with minimal overhead, but as
    a consequence, the likelihood of results being skewed by GC. ]
class Poller::Raw does Poller {
    method gc(::?CLASS:_: --> False) { }

    method pull-one {
        use nqp;
        nqp::stmts(
          (my uint $ns = $!ns),
          (my $n = 0),
          nqp::while(
            nqp::isge_i(($ns = nqp::sub_i($ns, $!it.pull-one)), 0),
            ($n++)),
          $n)
    }
}

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

    method pull-one {
        use nqp;
        nqp::stmts(
          nqp::if(
            nqp::cas($!sleeps, False, True),
            nqp::sleep($!seconds)),
          $!it.pull-one)
    }
}

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
