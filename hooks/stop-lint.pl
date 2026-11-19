#!/usr/bin/env perl
# Stop: lints every file the working tree changed, with the prose lint's
# checks. Hits exit 2, which keeps the turn going once; stop_hook_active lets the next stop through.
use strict;
use warnings;
use utf8;
use Encode ();
use FindBin;
use lib "$FindBin::RealBin/lib";
use Lint qw(read_input prose_hits structure_hits lint_view git_lines block);

my $MAX_FILES = 50;
my $MAX_BYTES = 1_000_000;

my ($raw, $decode) = read_input();
my $in = $decode->();
exit 0 if $in->{stop_hook_active};
my $cwd = $in->{cwd} // $ENV{CLAUDE_PROJECT_DIR} // '.';

my @report;

# Added lines per changed file, against HEAD; an untracked file counts as added whole.
my $root = join '', git_lines('-C', $cwd, 'rev-parse', '--show-toplevel');
chomp $root;
my %added;
# Names come NUL-separated, because git quotes paths with non-ASCII bytes or quotes otherwise.
if (length $root) {
    for my $file (split /\0/, join '', git_lines('-C', $root, 'diff', 'HEAD', '--name-only', '-z', '--diff-filter=AM')) {
        my $hunk;
        for (git_lines('-C', $root, 'diff', 'HEAD', '--unified=0', '--no-color', '--no-ext-diff', '--', $file)) {
            $hunk ||= /^@@/;
            $added{$file} .= Encode::decode('UTF-8', $_) if $hunk && s/^\+//;
        }
    }
    $added{$_} = undef for split /\0/, join '', git_lines('-C', $root, 'ls-files', '--others', '--exclude-standard', '-z');
}

my $checked = 0;
for my $rel (sort keys %added) {
    last if ++$checked > $MAX_FILES;
    my $path = "$root/$rel";
    next unless -f $path && -s _ <= $MAX_BYTES;
    my $text = do { open my $fh, '<:raw', $path or next; local $/; Encode::decode('UTF-8', <$fh> // '') };
    my ($whole, %opt) = lint_view($path, $text) or next;
    my ($new) = defined $added{$rel} ? lint_view($path, $added{$rel}) : ($whole);
    next unless defined $new && $new =~ /\S/;
    my @hits = (prose_hits($new, 0), structure_hits($whole, $new, %opt));
    push @report, Encode::decode('UTF-8', $rel) . ': ' . join(', ', @hits) if @hits;
}

block('stop-lint', 'AI-writing tells before finishing:', @report,
      'Fix the files per the Writing rules in AGENTS.md.') if @report;
exit 0;
