#!/usr/bin/env perl
# Caps how many subagents run at once in a session (STYLE_AGENTS_MAX_SUBAGENTS, default 3).
#   PreToolUse(Agent)  blocks the call at the cap, else reserves a slot
#   SubagentStart      turns the oldest reservation into a running agent
#   SubagentStop       frees the agent's slot
# A reservation that no SubagentStart claims expires after two minutes, for example when
# the user denies the call. A running agent expires after two hours, in case its stop never fires.
use strict;
use warnings;
use Fcntl qw(:flock SEEK_SET);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::RealBin/lib";
use JSON::PP ();
use Lint qw(read_input block);

my $PENDING_TTL = 120;
my $RUNNING_TTL = 7200;

my ($raw, $decode) = read_input();
my $in    = $decode->();
my $event = $in->{hook_event_name} // exit 0;

my $max = $ENV{STYLE_AGENTS_MAX_SUBAGENTS} // 3;
block('agent-cap', "STYLE_AGENTS_MAX_SUBAGENTS must be a positive integer, got '$max'") unless $max =~ /^[1-9]\d*$/;

my $dir = ($ENV{XDG_CACHE_HOME} // "$ENV{HOME}/.cache") . '/style-agents';
make_path($dir);
(my $session = $in->{session_id} // 'nosession') =~ s/[^A-Za-z0-9-]+/-/g;
open my $fh, '+>>', "$dir/agents-$session.json" or exit 0;
flock $fh, LOCK_EX or exit 0;
seek $fh, 0, SEEK_SET;
my $json  = JSON::PP->new->canonical;
my $state = eval { $json->decode(do { local $/; <$fh> // '' }) } || {};
my $now   = time;
my @pending = grep { $now - $_ < $PENDING_TTL } @{ $state->{pending} // [] };
my %running = map { $_ => $state->{running}{$_} } grep { $now - $state->{running}{$_} < $RUNNING_TTL } keys %{ $state->{running} // {} };

if ($event eq 'PreToolUse') {
    my $busy = @pending + keys %running;
    if ($busy >= $max) {
        close $fh;
        block('agent-cap', "$busy subagents are already running, the session cap is $max.",
              'Wait for one to finish, or do this slice yourself.');
    }
    push @pending, $now;
}
elsif ($event eq 'SubagentStart') {
    shift @pending;
    $running{ $in->{agent_id} } = $now if defined $in->{agent_id};
}
elsif ($event eq 'SubagentStop') {
    delete $running{ $in->{agent_id} } if defined $in->{agent_id};
}

truncate $fh, 0;
print {$fh} $json->encode({ pending => \@pending, running => \%running });
close $fh;
exit 0;
