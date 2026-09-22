#!/usr/bin/env perl
# PostToolUse(Write|Edit|MultiEdit): formats the edited file, then lints new prose.
# Formatting is silent. Lint hits exit 2 so the agent sees them; the edit itself stays.
use strict;
use warnings;
use utf8;
use File::Basename qw(basename dirname);
use FindBin;
use lib "$FindBin::RealBin/lib";
use Lint qw(read_input strip_code prose_hits block);

my ($raw, $decode) = read_input();
my $in   = $decode->();
my $ti   = $in->{tool_input} // {};
my $file = $ti->{file_path} or exit 0;
exit 0 unless -f $file;

my $root = $ENV{CLAUDE_PROJECT_DIR} // $in->{cwd} // '/';

sub has_cmd { my $c = shift; grep { -x "$_/$c" } split /:/, $ENV{PATH} // '' }

# Nearest file named in @names, walking up from the edited file to the project root.
sub find_up {
    my @names = @_;
    my $dir = dirname($file);
    while (1) {
        for (@names) { return "$dir/$_" if -e "$dir/$_" }
        last if $dir eq $root || $dir eq '/' || -e "$dir/.git";
        $dir = dirname($dir);
    }
    return;
}

sub file_has {
    my ($path, $re) = @_;
    open my $fh, '<', $path or return 0;
    local $/;
    return (<$fh> // '') =~ $re;
}

sub prettier {
    my $cfg = find_up(qw(.prettierrc .prettierrc.json .prettierrc.yaml .prettierrc.yml .prettierrc.js
                         .prettierrc.cjs .prettierrc.mjs .prettierrc.toml prettier.config.js
                         prettier.config.cjs prettier.config.mjs));
    unless ($cfg) {
        my $pkg = find_up('package.json');
        return unless $pkg && file_has($pkg, qr/"prettier"\s*:/);
        $cfg = $pkg;
    }
    my $local = dirname($cfg) . '/node_modules/.bin/prettier';
    return -x $local ? [$local, '--write', $file] : has_cmd('prettier') ? ['prettier', '--write', $file] : ();
}

sub python {
    my $pyproject = find_up('pyproject.toml');
    return ['ruff', 'format', $file]
        if has_cmd('ruff') && (find_up('ruff.toml', '.ruff.toml') || ($pyproject && file_has($pyproject, qr/^\[tool\.ruff/m)));
    return ['black', '-q', $file] if has_cmd('black') && $pyproject && file_has($pyproject, qr/^\[tool\.black\]/m);
    return;
}

sub nix {
    my $flake = find_up('flake.nix') or return;
    return ['alejandra', '-q', $file] if has_cmd('alejandra') && file_has($flake, qr/alejandra/);
    return ['nixfmt', $file]          if has_cmd('nixfmt') && file_has($flake, qr/nixfmt/);
    return;
}

sub rust {
    return unless has_cmd('rustfmt');
    my $cargo   = find_up('Cargo.toml');
    my $edition = $cargo && file_has($cargo, qr/^edition\s*=\s*"(\d{4})"/m) ? $1 : '2021';
    return ['rustfmt', '--edition', $edition, $file];
}

# Canonical formatters always run; the rest only when the project opts in with a config.
sub formatter {
    return ['treefmt', '--quiet', $file] if has_cmd('treefmt') && find_up('treefmt.toml', '.treefmt.toml');
    my ($ext) = $file =~ /\.([^.\/]+)$/ or return;
    $ext = lc $ext;
    return ['gofmt', '-w', $file] if $ext eq 'go' && has_cmd('gofmt');
    return rust()                  if $ext eq 'rs';
    return ['zig', 'fmt', $file]   if $ext eq 'zig' && has_cmd('zig');
    return prettier()              if $ext =~ /^(?:[cm]?[jt]sx?|json|css|scss|less|html|vue|svelte|ya?ml|mdx?)$/;
    return python()                if $ext eq 'py';
    return nix()                   if $ext eq 'nix';
    return ['stylua', $file]       if $ext eq 'lua' && has_cmd('stylua') && find_up('stylua.toml', '.stylua.toml');
    return ['clang-format', '-i', $file]
        if $ext =~ /^(?:c|h|cc|cpp|hpp|cxx)$/ && has_cmd('clang-format') && find_up('.clang-format');
    return;
}

if (my $fmt = formatter()) {
    open my $null, '>', '/dev/null';
    my $pid = fork // exit 0;
    if (!$pid) { open STDOUT, '>&', $null; open STDERR, '>&', $null; exec 'timeout', '20', @$fmt; exit 127 }
    waitpid $pid, 0;
}

# Prose lint: only the text this edit added, only in prose files, never in instruction files.
exit 0 unless $file =~ /\.(?:md|mdx|markdown|txt|rst|adoc)$/i;
exit 0 if basename($file) =~ /^(?:AGENTS|CLAUDE|GEMINI|SKILL)\.md$/i;

my $new = join "\n", grep { defined } $ti->{content}, $ti->{new_string},
    map { $_->{new_string} } @{ $ti->{edits} // [] };
exit 0 unless length $new;

# Codebase wins: skip the dash check when the rest of the file already uses dashes.
my $whole = do { open my $fh, '<:utf8', $file or exit 0; local $/; <$fh> // '' };
my $dashes_in = sub { my $n = () = strip_code(shift) =~ /[—–]/g; $n };
my $check_dashes = $dashes_in->($whole) <= $dashes_in->($new);

my @hits = prose_hits($new, $check_dashes);
block("prose-lint $file", 'AI-writing tells: ' . join(', ', @hits),
      'Rewrite those sentences per the Writing rules in AGENTS.md.') if @hits;
exit 0;
