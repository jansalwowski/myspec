#!/usr/bin/env perl
# Helper for evals/_fixtures/project-instructions.sh. Mirrors how Claude Code
# 2.1.284 turns a project's memory files into the text the model sees.
#
#   project-instructions.pl render <workspace>   print the rendered instructions
#   project-instructions.pl tags <prompt.md>     print its frontmatter tags, one per line
#   project-instructions.pl keys <prompt.md>     print its top-level frontmatter keys
#
# What Claude Code does, and this copies:
# - Files: CLAUDE.md, then .claude/rules/**/*.md, sorted. A rule is left out
#   when its frontmatter `paths:` names a real glob: Claude Code drops a
#   trailing `/**` from each glob and treats a rule whose globs are then empty
#   or all `**` as always loaded. A path-scoped rule loads in a real session
#   once the agent reads a matching file, which a system prompt cannot mirror.
# - Content: the leading frontmatter is removed with Claude Code's own pattern
#   /^---\s*\n([\s\S]*?)---\s*\n?/. When the text contains `<!--`, block-level
#   HTML comments are removed the way its markdown lexer finds them: a comment
#   that starts a line (up to 3 spaces in, outside fenced code) through the
#   line holding `-->`, plus the newlines after it; the whole block goes when
#   nothing but whitespace is left. Inline comments inside a paragraph stay.
# - Layout: the preamble, then one entry per file, each "Contents of <path>
#   (project instructions, checked into the codebase):\n\n" + trimmed content,
#   joined by blank lines.
# Deliberate difference: <path> is repo-relative. Claude Code prints the
# absolute path of the run's random scratch workspace, which is unknown when
# the text is generated.

use strict;
use warnings;

my $PREAMBLE = 'Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.';

sub slurp {
  my ($p) = @_;
  open(my $fh, '<', $p) or die "project-instructions.pl: cannot read $p: $!\n";
  local $/;
  my $s = <$fh>;
  close $fh;
  $s = '' unless defined $s;
  $s =~ s/\A\x{FEFF}//;
  $s =~ s/\r\n/\n/g;
  return $s;
}

# (frontmatter, body) with Claude Code's frontmatter pattern.
sub split_frontmatter {
  my ($s) = @_;
  if ($s =~ /\A---\s*\n([\s\S]*?)---\s*\n?/) {
    return ($1, substr($s, $+[0]));
  }
  return ('', $s);
}

sub unquote {
  my ($v) = @_;
  $v =~ s/^\s+|\s+$//g;
  $v =~ s/\s+#.*$// unless $v =~ /^["']/;
  if ($v =~ /^"(.*)"$/s) { $v = $1; $v =~ s/\\(.)/$1/g; }
  elsif ($v =~ /^'(.*)'$/s) { $v = $1; $v =~ s/''/'/g; }
  return $v;
}

# Values of a top-level key: an inline scalar, a [a, b] flow list (which may
# wrap onto following lines), or a block list of "- item" lines. Returns
# (found, values...). A flow list with no closing `]` exits 2, so a caller
# never mistakes it for a list without the value it looks for.
sub key_values {
  my ($fm, $key) = @_;
  my @lines = split /\n/, $fm;
  for (my $i = 0; $i < @lines; $i++) {
    next unless $lines[$i] =~ /^\Q$key\E:[ \t]*(.*?)[ \t]*$/;
    my $v = $1;
    my @vals;
    if ($v =~ /^\[/) {
      $v =~ s/[ \t]+#[^\]]*$//;
      while ($v !~ /\][ \t]*$/) {
        # A flow list continues only on indented lines; the next unindented
        # line is another key, so the list never closed.
        if ($i + 1 >= @lines || $lines[$i + 1] !~ /^[ \t]/) {
          print STDERR "project-instructions.pl: `$key:` opens a [ list that never closes\n";
          exit 2;
        }
        (my $next = $lines[++$i]) =~ s/^[ \t]+|[ \t]+$//g;
        $next =~ s/[ \t]+#[^\]]*$//;
        $v .= " $next";
      }
    }
    if ($v ne '' && $v !~ /^#/) {
      if ($v =~ /^\[(.*)\][ \t]*$/s) { @vals = map { unquote($_) } split /,/, $1; }
      else { @vals = map { unquote($_) } split /,/, $v; }
    } else {
      while ($i + 1 < @lines && $lines[$i + 1] =~ /^[ \t]*-[ \t]+(.*)$/) {
        push @vals, unquote($1);
        $i++;
      }
    }
    return (1, grep { $_ ne '' } @vals);
  }
  return (0);
}

sub path_scoped {
  my ($fm) = @_;
  my ($found, @globs) = key_values($fm, 'paths');
  return 0 unless $found;
  my @g = grep { $_ ne '' } map { my $x = $_; $x =~ s{/\*\*$}{}; $x } @globs;
  return 0 if !@g || !grep { $_ ne '**' } @g;
  return 1;
}

sub strip_html_comments {
  my ($s) = @_;
  return $s if index($s, '<!--') < 0;
  my @l = split /(?<=\n)/, $s;
  my ($out, $fence_ch, $fence_len) = ('', undef, 0);
  my $i = 0;
  while ($i < @l) {
    my $line = $l[$i];
    if (defined $fence_ch) {
      $out .= $line;
      undef $fence_ch if $line =~ /^ {0,3}(\Q$fence_ch\E{$fence_len,})[ \t]*\n?$/;
      $i++;
      next;
    }
    if ($line =~ /^ {0,3}((`)`{2,}|(~)~{2,})/) {
      ($fence_ch, $fence_len) = (defined $2 ? '`' : '~', length $1);
      $out .= $line;
      $i++;
      next;
    }
    if ($line =~ /^ {0,3}<!--/) {
      my ($raw, $j) = ($line, $i);
      while ($raw !~ /<!--[\s\S]*?-->/ && $j + 1 < @l) { $j++; $raw .= $l[$j]; }
      while ($j + 1 < @l && $l[$j + 1] eq "\n") { $j++; $raw .= $l[$j]; }
      (my $kept = $raw) =~ s/<!--[\s\S]*?-->//g;
      $out .= $kept if $kept =~ /\S/;
      $i = $j + 1;
      next;
    }
    $out .= $line;
    $i++;
  }
  return $out;
}

sub trim { my ($s) = @_; $s =~ s/^\s+|\s+$//g; return $s; }

sub rules_under {
  my ($dir) = @_;
  my @out;
  opendir(my $dh, $dir) or return ();
  for my $e (sort readdir $dh) {
    next if $e eq '.' || $e eq '..';
    my $p = "$dir/$e";
    if (-d $p) { push @out, rules_under($p); }
    elsif ($e =~ /\.md$/ && -f $p) { push @out, $p; }
  }
  closedir $dh;
  return @out;
}

sub render {
  my ($ws) = @_;
  chdir $ws or die "project-instructions.pl: cannot enter $ws: $!\n";
  my @files;
  push @files, 'CLAUDE.md' if -f 'CLAUDE.md';
  push @files, sort { $a cmp $b } rules_under('.claude/rules') if -d '.claude/rules';
  my @entries;
  for my $f (@files) {
    my ($fm, $body) = split_frontmatter(slurp($f));
    next if $f ne 'CLAUDE.md' && path_scoped($fm);
    my $content = trim(strip_html_comments($body));
    next if $content eq '';
    push @entries, "Contents of $f (project instructions, checked into the codebase):\n\n$content";
  }
  print join("\n\n", $PREAMBLE, @entries) if @entries;
}

sub prompt_frontmatter {
  my ($p) = @_;
  my $s = slurp($p);
  return $s =~ /\A---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|\z)/ ? $1 : '';
}

my ($cmd, $arg) = @ARGV;
die "usage: project-instructions.pl render <workspace> | tags <prompt.md> | keys <prompt.md>\n" unless defined $arg;
if ($cmd eq 'render') { render($arg); }
elsif ($cmd eq 'tags') { my ($found, @t) = key_values(prompt_frontmatter($arg), 'tags'); print "$_\n" for @t; }
elsif ($cmd eq 'keys') { for (split /\n/, prompt_frontmatter($arg)) { print "$1\n" if /^([A-Za-z_][\w-]*):/; } }
else { die "project-instructions.pl: unknown command $cmd\n"; }
