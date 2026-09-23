package Lint;
# Shared checks for the hook scripts. Mirrors the Writing and Commits rules in AGENTS.md.
use strict;
use warnings;
use utf8;
use Digest::SHA ();
use File::Path qw(make_path);
use JSON::PP ();
use Exporter 'import';
our @EXPORT_OK = qw(read_input strip_code prose_hits conventional attribution_hit block
                    signs_with_1password ssh_via_1password op_running risky_paths secret_hits gitleaks_staged have_cmd git_lines
                    index_fingerprint review_file record_review last_review OP_STOP);

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

# Files that should not enter a commit, by name.
my @RISKY_PATH = (
    qr/(?:^|\/)\.env(?:\.|$)/i, qr/(?:^|\/)id_(?:rsa|dsa|ecdsa|ed25519)$/, qr/\.(?:pem|key|p12|pfx|keystore|jks)$/i,
    qr/(?:^|\/)(?:credentials|secrets?|service-account.*)\.(?:json|ya?ml|toml)$/i, qr/(?:^|\/)\.(?:npmrc|pypirc|netrc|htpasswd)$/,
    qr/(?:^|\/)settings\.local\.json$/, qr/(?:^|\/)(?:node_modules|target|dist|build|\.direnv|__pycache__|vendor)\//,
    qr/(?:^|\/)result(?:-\w+)?$/, qr/\.(?:sqlite3?|db|dump|bak|log)$/i, qr/(?:^|\/)\.DS_Store$/,
);

# Secrets in the staged content itself.
my @SECRET = (
    [qr/-----BEGIN [A-Z ]*PRIVATE KEY-----/,      'private key block'],
    [qr/\bAKIA[0-9A-Z]{16}\b/,                    'AWS access key id'],
    [qr/\b(?:ghp|gho|ghu|ghs)_[A-Za-z0-9]{30,}/,  'GitHub token'],
    [qr/\bgithub_pat_[A-Za-z0-9_]{30,}/,          'GitHub fine-grained token'],
    [qr/\bsk-[A-Za-z0-9_-]{20,}/,                 'API secret key (sk-)'],
    [qr/\bxox[abprs]-[A-Za-z0-9-]{10,}/,          'Slack token'],
    [qr/\bAIza[0-9A-Za-z_-]{35}\b/,               'Google API key'],
    [qr/\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, 'JWT'],
    [qr/(?:password|passwd|secret(?:[_-]?key)?|api[_-]?key|access[_-]?token|token)\s*[:=]\s*["'][^"'\s]{8,}["']/i,
        'hardcoded credential'],
);

sub risky_paths {
    my ($cwd, @paths) = @_;
    my @bad;
    for my $p (@paths) {
        chomp $p;
        next unless length $p;
        push @bad, "$p (name)" and next if grep { $p =~ $_ } @RISKY_PATH;
        my $abs = $p =~ m{^/} ? $p : "$cwd/$p";
        my $size = -f $abs ? -s $abs : 0;
        push @bad, sprintf('%s (%.1f MB)', $p, $size / 1e6) if $size > 1_000_000;
    }
    return @bad;
}

sub secret_hits {
    my ($text) = @_;
    my @hits;
    for (@SECRET) { push @hits, $_->[1] if $text =~ $_->[0] }
    my %seen;
    return grep { !$seen{$_}++ } @hits;
}

sub have_cmd { my $c = shift; scalar grep { -x "$_/$c" } split /:/, $ENV{PATH} // '' }

# Scans the staged diff with gitleaks, returning one line per finding.
sub gitleaks_staged {
    my ($cwd) = @_;
    open my $saved, '>&', \*STDERR;
    open STDERR, '>', '/dev/null';
    my ($gl, $json);
    if (open $gl, '-|', 'timeout', '30', 'gitleaks', 'git', '--staged', '--no-banner', '--redact',
        '-f', 'json', '-r', '-', $cwd) {
        local $/;
        $json = <$gl> // '';
        close $gl;
    }
    open STDERR, '>&', $saved;
    my $found = eval { JSON::PP->new->decode($json // '[]') } || [];
    return map { ($_->{RuleID} // 'secret') . ' in ' . ($_->{File} // '?') . ':' . ($_->{StartLine} // '?') } @$found;
}

# Identity of the current index: changes whenever staged paths or their contents change.
sub index_fingerprint {
    my ($cwd) = @_;
    my $raw = join '', git_lines('-C', $cwd, 'diff', '--cached', '--raw');
    return length $raw ? Digest::SHA::sha1_hex($raw) : '';
}

# Where the last reviewed fingerprint for this session and repo is remembered.
sub review_file {
    my ($cwd, $session) = @_;
    my $root = join '', git_lines('-C', $cwd, 'rev-parse', '--show-toplevel');
    chomp $root;
    return unless length $root;
    my $dir = ($ENV{XDG_CACHE_HOME} // "$ENV{HOME}/.cache") . '/style-agents';
    make_path($dir);
    (my $key = "$root-" . ($session // 'nosession')) =~ s/[^A-Za-z0-9]+/-/g;
    return "$dir/$key";
}

sub record_review {
    my ($file, $fingerprint) = @_;
    return unless $file;
    open my $fh, '>', $file or return;
    print {$fh} $fingerprint;
}

sub last_review {
    my ($file) = @_;
    return '' unless $file && open my $fh, '<', $file;
    local $/;
    return <$fh> // '';
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
