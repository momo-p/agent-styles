#!/usr/bin/env perl
# PreToolUse(Bash): enforces the commit and PR rules in AGENTS.md. Exit 2 blocks the command.
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/lib";
use Lint qw(read_input prose_hits structure_hits conventional attribution_hit block signs_with_1password ssh_via_1password
            op_running risky_paths secret_hits gitleaks_staged have_cmd git_lines
            index_fingerprint review_file record_review last_review OP_STOP);

my ($raw, $decode) = read_input();
# Cheap pre-filter so unrelated Bash calls never pay for JSON decoding.
exit 0 unless $raw =~ /git\s+(?:status|diff|commit|tag|config|push|pull|fetch|clone)|gh\s+pr\s+(?:create|edit)|gpgsign|gpg-sign/;

my $in  = $decode->();
my $cmd = $in->{tool_input}{command} // '';
my $cwd = $in->{cwd} // '.';

block('signing', 'Signing is required; never bypass it. If signing failed, the fix is on the user\'s side.', OP_STOP)
    if $cmd =~ /--no-gpg-sign|\b(?:commit|tag)\.gpgsign\s*=?\s*false|git\s+config\b[^\n;&|]*\b(?:commit|tag)\.gpgsign|git\s+config\b[^\n;&|]*\bgpg\.(?:format|ssh\.program)/;

block('1password', '1Password is not running, so this commit cannot be signed.', OP_STOP)
    if $cmd =~ /git\s+(?:commit|tag\s+-[sa])\b/ && signs_with_1password($cwd) && !op_running();

block('1password', '1Password is not running, and SSH auth for this remote goes through its agent.', OP_STOP)
    if $cmd =~ /git\s+(?:push|pull|fetch|clone)\b/ && ssh_via_1password($cwd, $cmd) && !op_running();

# Staging is not checked as it happens; the index is checked once, when the commit is attempted.
# Looking at the index counts as reviewing it, so remember what was on screen at that moment.
if ($cmd =~ /git\s+(?:status|diff\s+[^\n;&|]*--(?:cached|staged)|diff\s+HEAD)\b/) {
    record_review(review_file($cwd, $in->{session_id}), index_fingerprint($cwd));
}

if ($cmd =~ /git\s+commit\b/ && $cmd !~ /--amend[^\n]*--no-edit/) {
    my @staged = git_lines('-C', $cwd, 'diff', '--cached', '--name-only');
    push @staged, git_lines('-C', $cwd, 'diff', '--name-only') if $cmd =~ /git\s+commit\s+(?:-\w*a|--all)\b/;
    my @bad = risky_paths($cwd, @staged);
    block('staged files', 'These staged paths should not be committed:', @bad,
          'Unstage them (git restore --staged <path>), then commit.') if @bad;

    my ($scanner, @secrets) = have_cmd('gitleaks')
        ? ('gitleaks', gitleaks_staged($cwd))
        : ('pattern match, gitleaks not installed', secret_hits(join '', git_lines('-C', $cwd, 'diff', '--cached', '-U0')));
    block('secret', "The staged diff contains what looks like a secret, per $scanner:", @secrets,
          'Do not commit it. Show the user these lines and ask what to do.') if @secrets;

    my $now = index_fingerprint($cwd);
    my $file = review_file($cwd, $in->{session_id});
    block('unreviewed', 'The index changed since you last looked at it, so this commit would include files you have not seen.',
          'Run git diff --cached, confirm it is exactly what you mean to commit, then commit again.')
        if $now && last_review($file) ne $now;
}

my $QUOTED = qr/"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+)/s;

sub unquote { my $s = $_[0] // ''; $s =~ s/\\(["\\\$`])/$1/g; $s }

sub flag_values {
    my ($flags) = @_;
    my @vals;
    while ($cmd =~ /(?:^|\s)(?:$flags)(?:=|\s+)$QUOTED/g) {
        push @vals, defined $1 ? unquote($1) : $2 // $3;
    }
    return @vals;
}

sub heredoc { $cmd =~ /<<-?\s*['"]?(\w+)['"]?[^\n]*\n(.*?)\n\s*\1\b/s ? $2 : undef }

block('attribution', 'Remove the attribution trailer; AGENTS.md forbids attribution.')
    if $cmd =~ /git\s+commit|gh\s+pr/ && attribution_hit($cmd);

if ($cmd =~ /git\s+commit\b/) {
    block('commit', 'Pass the message with a single -m "<type>(<scope>): <subject>"; no -F or heredoc.')
        if $cmd =~ /\s(?:-F|--file)\b/ || ($cmd =~ /git\s+commit[^\n]*<</);
    my @msgs = flag_values('-[a-zA-Z]*m|--message');
    block('commit', 'One -m only: a single subject line, no body.') if @msgs > 1;
    if (@msgs) {
        my $subject = $msgs[0];
        block('commit', 'Message must be one line, no body.') if $subject =~ /\n/;
        block('commit', "Not a conventional subject: \"$subject\"",
              'Use <type>(<scope>): <what changed>, e.g. feat(api): add pagination to list endpoints')
            unless conventional($subject);
        my @hits = prose_hits($subject, 1);
        block('commit', "Subject has AI-writing tells: @{[join ', ', @hits]}") if @hits;
    }
}

if ($cmd =~ /gh\s+pr\s+(?:create|edit)\b/) {
    for my $title (flag_values('--title|-t')) {
        block('pr', "Title is not a conventional subject: \"$title\"") unless conventional($title);
    }
    my ($body) = flag_values('--body|-b');
    $body = heredoc() if !defined $body || $body =~ /^\$\(cat/;
    if (!defined $body and my ($file) = flag_values('--body-file|-F')) {
        $file = "$cwd/$file" unless $file =~ m{^/};
        if (open my $fh, '<:utf8', $file) { local $/; $body = <$fh> }
    }
    if (defined $body) {
        $body =~ s/\s+\z//;
        my @problems;
        my $lines = () = $body =~ /^/mg;
        push @problems, "$lines lines; max 10" if $lines > 10;
        push @problems, 'no headings' if $body =~ /^\s*#/m;
        push @problems, 'no code blocks' if $body =~ /^\s*```/m;
        my $bullets = () = $body =~ /^\s*[-*] /mg;
        push @problems, "$bullets bullets; max 5" if $bullets > 5;
        my @hits = (prose_hits($body, 1), structure_hits($body, undef, min_lines => 3));
        push @problems, 'AI-writing tells: ' . join(', ', @hits) if @hits;
        block('pr', 'Body breaks the PR rules in AGENTS.md:', @problems) if @problems;
    }
}

exit 0;
