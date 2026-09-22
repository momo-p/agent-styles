#!/usr/bin/env perl
# PostToolUseFailure(Bash): a failed or timed-out git command that points at 1Password (locked,
# closed, or waiting for approval) tells the agent to stop and hand over to the user.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/lib";
use JSON::PP ();
use Lint qw(read_input block OP_STOP);

my ($raw, $decode) = read_input();
exit 0 unless $raw =~ /\bgit\b/;

my $in  = $decode->();
my $cmd = $in->{tool_input}{command} // '';
exit 0 unless $cmd =~ /\bgit\s+(?:commit|tag|push|pull|fetch|clone|merge|rebase|cherry-pick|revert|am)\b/;

my $SIGNS = do {
    my @phrases = ('1password', 'op-ssh-sign', 'agent refused operation', 'signing failed',
        'failed to write commit object', 'communication with agent failed',
        'could not open a connection to your authentication agent', 'permission denied (publickey)',
        "error: couldn't get agent", 'gpg failed to sign', 'failed to sign the data', 'incorrect passphrase');
    my $alt = join '|', map { quotemeta } @phrases;
    qr/$alt/i;
};
my $TIMEOUT = qr/timed out|timeout|interrupted/i;

# Match only the failure output, never the command or tool parameters (the Bash tool has a timeout field).
my %rest = %$in;
delete $rest{tool_input};
my $out = JSON::PP->new->encode(\%rest);

block('1password', 'This git command failed on signing or SSH auth.', OP_STOP) if $out =~ $SIGNS;
block('1password', 'This git command timed out; it is most likely waiting for a 1Password approval prompt.', OP_STOP)
    if $out =~ $TIMEOUT;
exit 0;
