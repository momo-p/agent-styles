package Lint;
# Shared checks for the hook scripts. Mirrors the Writing and Commits rules in AGENTS.md.
use strict;
use warnings;
use utf8;
use Digest::SHA ();
use File::Basename ();
use File::Path qw(make_path);
use JSON::PP ();
use Exporter 'import';
our @EXPORT_OK = qw(read_input strip_code prose_hits structure_hits structure_report lint_view prose_text comment_text conventional attribution_hit block
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

# The file that remembers the last reviewed fingerprint for this session and repo.
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


# Text a reader actually sees, without fenced blocks, links, quotes, tables and headings.
# Line and paragraph breaks stay, so the closer check can find the end of each block.
# Inline code becomes \x01, so the checks skip a terse line of API names.
sub prose_text {
    my ($text) = @_;
    $text =~ s/^[ \t]*(```|~~~).*?^[ \t]*\1[^\n]*$/\n/gms;
    $text =~ s/<!--.*?-->//gs;
    $text =~ s/`[^`\n]*`/\x01/g;
    $text =~ s{https?://\S+}{}g;
    $text =~ s/\[([^\]\n]*)\]\([^)\n]*\)/$1/g;
    $text =~ s/^[ \t]*[>|#][^\n]*$//mg;
    return $text;
}

# Prose blocks: every bullet stands alone, consecutive plain lines join into a paragraph.
sub _blocks {
    my ($text) = @_;
    my (@blocks, @cur);
    my $flush = sub { push @blocks, join(' ', @cur) if @cur; @cur = () };
    for my $line (split /\n/, $text) {
        if    ($line !~ /\S/)                      { $flush->() }
        elsif ($line =~ /^\s*(?:[-*+]|\d+[.)])\s/) { $flush->(); push @blocks, $line }
        else                                       { push @cur, $line }
    }
    $flush->();
    return grep { /\S/ } @blocks;
}

# Sentences of a block, with the bullet marker and any bold lead-in label dropped.
sub _sentences {
    my ($block) = @_;
    $block =~ s/^\s*(?:[-*+]|\d+[.)])\s+//;
    $block =~ s/^\*\*[^*\n]+\*\*:?\s*//;
    return grep { /\S/ } split /(?<=[.!?])\s+/, $block;
}

# Short declarative sentences that close a block which already made its point, plus the
# one-sentence paragraph dropped after a full one. Colons, digits and code spans rule a
# sentence out: it is carrying detail rather than restating.
sub _closers {
    my ($text) = @_;
    my ($n, $prev_full) = (0, 0);
    for my $block (_blocks($text)) {
        my @s = _sentences($block);
        next unless @s;
        my $last  = $s[-1];
        my $words = () = $last =~ /\S+/g;
        my $short = $last =~ /[.!?]\s*$/ && $last !~ /[\x01\d:;]/ && $words >= 3 && $words <= 9;
        $n++ if $short && (@s > 1 || $prev_full);
        $prev_full = @s > 1;
    }
    return $n;
}

# Passive voice, which STE asks code comments to avoid. It matches a form of "be", an
# optional adverb or "not", then a regular past participle or a common irregular one.
my $IRREGULAR = join '|', qw(built done found given kept known left made meant met put read run seen sent set shown
    taken written held chosen drawn driven broken spent split told thought brought caught taught hidden begun cut
    got gotten hit lost paid said sold shut understood bound fed led thrown);
my $PASSIVE = qr/\b(?:is|are|was|were|be|been|being)\s+(?:(?:not|\w+ly)\s+)?(?:\w+ed|$IRREGULAR)\b/i;

# Sentences longer than $max words. A wrapped line joins the sentence it continues. A line
# starts a new sentence when it opens with a capital or follows a stop or colon.
sub _long_sentences {
    my ($text, $max) = @_;
    my (@paras, $cur);
    for my $line (split /\n/, $text) {
        if ($line !~ /\S/) { push @paras, $cur if defined $cur; undef $cur; next }
        if (!defined $cur || $cur =~ /[.!?:]\s*$/ || $line =~ /^\s*[A-Z]/) { push @paras, $cur if defined $cur; $cur = $line; next }
        $cur .= " $line";
    }
    push @paras, $cur if defined $cur;
    my $n = 0;
    for my $sentence (map { split /(?<=[.!?])\s+/ } @paras) {
        my $words = () = $sentence =~ /[\w'-]+/g;
        $n++ if $words > $max;
    }
    return $n;
}

# Raw counts of every structural tell, plus the prose volume they are judged against.
sub _counts {
    my ($text) = @_;
    my $p = prose_text($text);
    my %n;
    $n{lines}   = () = $p =~ /^[^\n]*\S[^\n]*$/mg;
    $n{$_}      = 0 for qw(antithesis triads dash closers bold bullets);
    $n{antithesis} = () = $p =~ /,\s+not\s+\w|\b(?:is|are|was|were)\s+not\s+(?:a|an|the)\b|\brather than\b|,\s+never\s/gi;
    # Only a run of exactly three counts; a genuine long enumeration is not a forced triad.
    while ($p =~ /((?:[\w'-]+,\s+)+[\w'-]+,?\s+and\s+[\w'-]+)/g) {
        my @items = grep { length } split /,\s*|\s+and\s+/, $1;
        $n{triads}++ if @items == 3;
    }
    $n{dash}       = () = $p =~ /[\x{2014}\x{2013}]|\s--\s/g;
    $n{closers}    = _closers($p);
    $n{bullets}    = () = $p =~ /^\s*(?:[-*+]|\d+[.)])\s+/mg;
    $n{bold}       = () = $p =~ /^\s*(?:[-*+]|\d+[.)])\s+\*\*[^*\n]+\*\*/mg;
    $n{passive}    = () = $p =~ /$PASSIVE/g;
    $n{long}       = _long_sentences($p, 25);
    return %n;
}

# How much of each tell a document may carry: [smallest count worth reporting, one per N
# prose lines]. A single contrast is good technical writing; one in every paragraph is the
# tic. These budgets fire on rate and scale with the document.
my %BUDGET = (
    antithesis => ['antithesis (X, not Y)', 3, 40],
    closers    => ['one-line closers',      4, 25],
    triads     => ['forced triads',         3, 50],
    dash       => ['em/en dash',            2, 80],
);

# Simplified Technical English rules, checked only with the ste option (code comments):
# STE caps descriptive sentences at 25 words and prefers the active voice.
my %STE = (
    long    => ['sentences over 25 words', 2, 30],
    passive => ['passive voice',           3, 20],
);

# Structural tells in $whole that $added fed, so untouched prose stays quiet. %opt turns
# off the checks that do not apply to a kind of text. Closers mean nothing in code
# comments, which are short single sentences by design. min_lines lowers the floor for
# text that is short by rule, such as a PR body capped at ten lines.
sub structure_hits {
    my ($whole, $added, %opt) = @_;
    my ($lines, @rows) = structure_report($whole, %opt);
    my %a = _counts($added // $whole);
    return map {
        $_->{key} eq 'bold'
            ? sprintf('bold lead-in labels on %d of %d bullets', $_->{count}, $_->{bullets})
            : sprintf('%s x%d in %d lines, over the 1 per %d budget', $_->{name}, $_->{count}, $lines, $_->{per})
    } grep { $_->{over} && $a{ $_->{key} } } @rows;
}

# Every structural tell in $text against its budget. Returns the prose line count, then
# one row per tell with the most it may carry. Text under min_lines is never over.
sub structure_report {
    my ($text, %opt) = @_;
    my %n     = _counts($text);
    my $short = $n{lines} < ($opt{min_lines} // 8);
    my @rows;
    for my $key (sort(keys %BUDGET), $opt{ste} ? sort(keys %STE) : ()) {
        next if $opt{"no_$key"};
        my ($name, $min, $per) = @{ $BUDGET{$key} // $STE{$key} };
        my $allowed = int($n{lines} / $per);
        $allowed = $min - 1 if $allowed < $min - 1;
        push @rows, { key => $key, name => $name, per => $per, count => $n{$key}, allowed => $allowed,
                      over => !$short && $n{$key} > $allowed };
    }
    unless ($opt{no_bold}) {
        my $allowed = int($n{bullets} * 2 / 5);
        $allowed = 4 if $allowed < 4;
        push @rows, { key => 'bold', name => 'bold lead-in labels', count => $n{bold}, allowed => $allowed,
                      bullets => $n{bullets}, over => !$short && $n{bold} > $allowed };
    }
    return ($n{lines}, @rows);
}

# Which comment syntax a source file uses. Anything unlisted has no prose to lint.
my %COMMENT = (
    slash => qr/\.(?:c|h|cc|cpp|hpp|cxx|go|rs|java|[cm]?[jt]sx?|dart|swift|kts?|scala|zig|php|cs|proto|gradle|groovy)$/i,
    hash  => qr/\.(?:py|pyi|rb|sh|bash|zsh|pl|pm|t|ya?ml|toml|nix|tf|just)$|(?:^|\/)(?:Makefile|Justfile|Dockerfile)[^\/]*$/,
    dash  => qr/\.(?:lua|sql|hs|elm|moon)$/i,
);

# The ast-grep language and comment node kinds for each extension it parses. Kind names
# differ per grammar, and a kind the grammar lacks fails the whole rule.
my %AST = (
    (map { $_ => ['c', 'comment'] } qw(c h)),
    (map { $_ => ['cpp', 'comment'] } qw(cc cpp hpp cxx)),
    (map { $_ => ['javascript', 'comment'] } qw(js mjs cjs jsx)),
    (map { $_ => ['typescript', 'comment'] } qw(ts mts cts)),
    tsx => ['tsx', 'comment'],     cs    => ['csharp', 'comment'],     go  => ['go', 'comment'],
    php => ['php', 'comment'],     rb    => ['ruby', 'comment'],       sh  => ['bash', 'comment'],
    bash => ['bash', 'comment'],   nix   => ['nix', 'comment'],        tf  => ['hcl', 'comment'],
    lua => ['lua', 'comment'],     hs    => ['haskell', 'comment'],    yml => ['yaml', 'comment'],
    yaml => ['yaml', 'comment'],   java  => ['java', qw(line_comment block_comment)],
    rs  => ['rust', qw(line_comment block_comment)],                   scala => ['scala', qw(comment block_comment)],
    kt  => ['kotlin', qw(line_comment multiline_comment)],             kts => ['kotlin', qw(line_comment multiline_comment)],
    swift => ['swift', qw(comment multiline_comment)],                 dart => ['dart', qw(comment block_comment)],
    py  => ['python', 'comment', 'docstring'],                         pyi => ['python', 'comment', 'docstring'],
);

# Comment nodes of $text parsed by ast-grep, markers stripped. Undef when ast-grep is not
# installed, does not parse this file type, or fails, so the caller falls back to regexes.
sub _ast_comments {
    my ($path, $text) = @_;
    my ($ext) = $path =~ /\.([^.\/]+)$/ or return;
    my ($lang, @kinds) = @{ $AST{ lc $ext } // return };
    return unless have_cmd('ast-grep');

    my @any = map { $_ eq 'docstring' ? '{kind: string, inside: {kind: expression_statement}}' : "{kind: $_}" } @kinds;
    require File::Temp;
    my $tmp = File::Temp->new(SUFFIX => ".$ext");
    binmode $tmp, ':utf8';
    print {$tmp} $text;
    close $tmp;

    open my $saved, '>&', \*STDERR;
    local $/ = "\n";
    open STDERR, '>', '/dev/null';
    my ($ag, @lines);
    @lines = <$ag> if open $ag, '-|', 'timeout', '10', 'ast-grep', 'scan', '--json=stream',
        '--inline-rules', "id: comment\nlanguage: $lang\nrule: {any: [" . join(', ', @any) . "]}", $tmp->filename;
    my $ok = $ag && close $ag;
    open STDERR, '>&', $saved;
    return unless $ok;

    my $json = JSON::PP->new->utf8;
    my @out;
    for (@lines) {
        my $c = eval { $json->decode($_)->{text} } // next;
        $c =~ s{^/\*+!?|\*+/$}{}g;
        $c =~ s/^--\[=*\[|\]=*\]$|^\{-|-\}$//g;
        $c =~ s/^[rRbBuU]*("""|'''|["'])(.*)\1$/$2/s;
        $c =~ s{^[ \t]*(?://[/!]?|#+|--+|\*+(?!/))[ \t]?}{}mg;
        $c =~ s/\s+\z//;
        push @out, $c;
    }
    return join "\n", @out;
}

# The comments and doc comments of a source file: the prose a reader meets inside code.
# ast-grep reads them from the syntax tree when installed. The regex fallback blanks string
# bodies first so a URL or a quoted "#" never reads as a comment.
sub comment_text {
    my ($path, $text) = @_;
    my $ast = _ast_comments($path, $text);
    return join "\n", grep { !/^!/ } split /\n/, $ast if defined $ast;
    $text =~ s/(["'])(?:\\.|(?!\1)[^\n])*\1/""/g;
    my @out;
    if ($path =~ $COMMENT{slash}) {
        push @out, $1 while $text =~ m{(?<![:\w/])/{2,3}[ \t]?([^\n]*)}g;
        push @out, $1 while $text =~ m{/\*+(.*?)\*/}gs;
    }
    elsif ($path =~ $COMMENT{hash}) {
        push @out, $1 while $text =~ /(?:^|\s)#+[ \t]?([^\n]*)/mg;
        push @out, $1 while $path =~ /\.pyi?$/ && $text =~ /"""(.*?)"""/gs;
    }
    elsif ($path =~ $COMMENT{dash}) {
        push @out, $1 while $text =~ /(?<![-\w])--[ \t]?([^\n]*)/g;
    }
    else { return }
    return join "\n", grep { !/^!/ } @out;
}

# The prose of $path a reader meets, and the budget options for it. A prose file counts
# whole. A source file counts by its comments, with the STE budgets in place of the closer
# and bold ones. Returns empty for the instruction files, which quote the tells they ban,
# and for any file with the opt-out marker.
sub lint_view {
    my ($path, $text) = @_;
    return if File::Basename::basename($path) =~ /^(?:AGENTS|CLAUDE|GEMINI)\.md$/i || $text =~ /prose-lint:\s*off/;
    return ($text) if $path =~ /\.(?:md|mdx|markdown|txt|rst|adoc)$/i;
    my $comments = comment_text($path, $text) // return;
    return ($comments, no_closers => 1, no_bold => 1, ste => 1);
}

1;
