package Lint;
# Shared checks for the hook scripts. Mirrors the Writing and Commits rules in AGENTS.md.
use strict;
use warnings;
use utf8;
use JSON::PP ();
use Exporter 'import';
our @EXPORT_OK = qw(read_input strip_code prose_hits conventional attribution_hit block
                    signs_with_1password ssh_via_1password op_running OP_STOP);

use constant OP_STOP => 'STOP. This is not a bug and not a git problem: git is waiting on 1Password '
    . '(signing or SSH key). Do not retry, do not disable signing, do not change git config. '
    . 'Tell the user, as the first line of your reply: "1Password needs you: open and unlock it, '
    . 'approve the prompt, then tell me to retry." Then wait.';

# Unambiguous tells: one sighting is enough.
my @HARD = (
    qr/\b(?:delve[sd]?|delving)\b/i,
    qr/\btapestry\b/i,
    qr/\btestament to\b/i,
    qr/\bpivotal\b/i,
    qr/\bseamless(?:ly)?\b/i,
    qr/\bshowcas(?:e|es|ed|ing)\b/i,
    qr/\bvibrant\b/i,
    qr/\bunderscor(?:es|ed|ing)\b/i,
    qr/\b(?:serves|stands) as\b/i,
    qr/\bboasts\b/i,
    qr/\bit'?s not (?:just|only|merely)\b/i,
    qr/\blet'?s dive in\b/i,
    qr/\bhere'?s the thing\b/i,
    qr/\bat its core\b/i,
    qr/\b(?:great question|i hope this helps|let me know if|happy coding|you'?re absolutely right)\b/i,
    qr/(?:^|\s)(?:certainly|of course)!/i,
);

# Words with legitimate technical uses: flag only when two or more share the text.
my @SOFT = (
    qr/\bcrucial\b/i, qr/\brobust\b/i, qr/\benhanc(?:e|es|ed|ing)\b/i,
    qr/\bleverag(?:e|es|ed|ing)\b/i, qr/\blandscape\b/i, qr/\bfoster(?:s|ed|ing)?\b/i,
    qr/\bintricate\b/i, qr/\bmeticulous(?:ly)?\b/i, qr/\bgame[- ]changer\b/i,
);

sub read_input {
    local $/;
    my $raw = <STDIN> // '';
    return ($raw, sub { JSON::PP->new->utf8->decode($raw) });
}

sub strip_code {
    my ($text) = @_;
    $text =~ s/^\s*(```|~~~).*?^\s*\1[^\n]*$//gms;
    $text =~ s/`[^`\n]*`//g;
    $text =~ s{https?://\S+}{}g;
    return $text;
}

# Returns the matched tells in $text. $check_dashes is false when the file already uses dashes.
sub prose_hits {
    my ($text, $check_dashes) = @_;
    $text = strip_code($text);
    my @hits;
    for my $re (@HARD) { push @hits, lc $1 while $text =~ /($re)/g }
    my @soft;
    for my $re (@SOFT) { push @soft, lc $1 if $text =~ /($re)/ }
    push @hits, @soft if @soft >= 2;
    push @hits, 'em/en dash' if $check_dashes && $text =~ /[—–]| -- /;
    my %seen;
    return grep { !$seen{$_}++ } @hits;
}

sub conventional {
    my ($subject) = @_;
    return $subject =~ /^(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(?:\([\w.\/,-]+\))?!?: \S/;
}

sub attribution_hit {
    my ($text) = @_;
    return $text =~ /co-authored-by:|generated with|claude\.ai\/code|🤖/i;
}

sub signs_with_1password {
    my ($cwd) = @_;
    my %cfg = map { split ' ', $_, 2 } git_lines('-C', $cwd, 'config', '--get-regexp', '^(commit\.gpgsign|gpg\.ssh\.program)$');
    chomp %cfg;
    return ($cfg{'commit.gpgsign'} // '') eq 'true' && ($cfg{'gpg.ssh.program'} // '') =~ /op-ssh-sign/;
}

# Output lines of a git command, with its stderr discarded.
sub git_lines {
    open my $saved, '>&', \*STDERR;
    open STDERR, '>', '/dev/null';
    my ($git, @out);
    @out = <$git> if open $git, '-|', 'git', @_;
    open STDERR, '>&', $saved;
    return @out;
}

# True when SSH auth goes through the 1Password agent and the command talks to an SSH remote.
sub ssh_via_1password {
    my ($cwd, $cmd) = @_;
    my $agent = ($ENV{SSH_AUTH_SOCK} // '') =~ /1password/i;
    if (!$agent and open my $cfg, '<', "$ENV{HOME}/.ssh/config") {
        $agent = grep { /^\s*identityagent\s+\S*1password/i } <$cfg>;
    }
    return 0 unless $agent;
    return 1 if $cmd =~ /git\s+clone\b[^\n;&|]*(?:\bgit@|ssh:\/\/)/;
    return scalar grep { /\s(?:\S+@|ssh:\/\/)/ } git_lines('-C', $cwd, 'remote', '-v');
}

sub op_running {
    for my $comm (glob '/proc/[0-9]*/comm') {
        open my $fh, '<', $comm or next;
        return 1 if (<$fh> // '') =~ /^1password/i;
    }
    return 0;
}

# Exit 2 sends the message to the agent; for PreToolUse it also blocks the call.
sub block {
    my ($prefix, @lines) = @_;
    binmode STDERR, ':utf8';
    print STDERR "$prefix: ", join("\n  ", @lines), "\n";
    exit 2;
}

1;
