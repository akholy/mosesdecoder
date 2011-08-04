#!/usr/bin/perl -w 
# $Id$
# Usage:
# mert-moses.pl <foreign> <english> <decoder-executable> <decoder-config>
# For other options see below or run 'mert-moses.pl --help'

# Notes:
# <foreign> and <english> should be raw text files, one sentence per line
# <english> can be a prefix, in which case the files are <english>0, <english>1, etc. are used

# Excerpts from revision history

# Jul 2011    simplifications (Ondrej Bojar), based on mert-moses.pl rev. 3887
#             -- rely on moses' -show-weights instead of parsing moses.ini 
#             -- got rid of the 'triples' mess;
#                use --range to supply bounds for random starting values:
#                --range tm:-3..3 --range lm:-3..3
# 5 Aug 2009  Handling with different reference length policies (shortest, average, closest) for BLEU 
#             and case-sensistive/insensitive evaluation (Nicola Bertoldi)
# 5 Jun 2008  Forked previous version to support new mert implementation.
# 13 Feb 2007 Better handling of default values for lambda, now works with multiple
#             models and lexicalized reordering
# 11 Oct 2006 Handle different input types through parameter --inputype=[0|1]
#             (0 for text, 1 for confusion network, default is 0) (Nicola Bertoldi)
# 10 Oct 2006 Allow skip of filtering of phrase tables (--no-filter-phrase-table)
#             useful if binary phrase tables are used (Nicola Bertoldi)
# 28 Aug 2006 Use either closest or average or shortest (default) reference
#             length as effective reference length
#             Use either normalization or not (default) of texts (Nicola Bertoldi)
# 31 Jul 2006 move gzip run*.out to avoid failure wit restartings
#             adding default paths
# 29 Jul 2006 run-filter, score-nbest and mert run on the queue (Nicola; Ondrej had to type it in again)
# 28 Jul 2006 attempt at foolproof usage, strong checking of input validity, merged the parallel and nonparallel version (Ondrej Bojar)
# 27 Jul 2006 adding the safesystem() function to handle with process failure
# 22 Jul 2006 fixed a bug about handling relative path of configuration file (Nicola Bertoldi) 
# 21 Jul 2006 adapted for Moses-in-parallel (Nicola Bertoldi) 
# 18 Jul 2006 adapted for Moses and cleaned up (PK)
# 21 Jan 2005 unified various versions, thorough cleanup (DWC)
#             now indexing accumulated n-best list solely by feature vectors
# 14 Dec 2004 reimplemented find_threshold_points in C (NMD)
# 25 Oct 2004 Use either average or shortest (default) reference
#             length as effective reference length (DWC)
# 13 Oct 2004 Use alternative decoders (DWC)
# Original version by Philipp Koehn

use FindBin qw($Bin);
use File::Basename;
use File::Path;
my $SCRIPTS_ROOTDIR = $Bin;
$SCRIPTS_ROOTDIR =~ s/\/training$//;
$SCRIPTS_ROOTDIR = $ENV{"SCRIPTS_ROOTDIR"} if defined($ENV{"SCRIPTS_ROOTDIR"});

## We preserve this bit of comments to keep the traditional weight ranges.
#
# # for each _d_istortion, _l_anguage _m_odel, _t_ranslation _m_odel and _w_ord penalty, there is a list
# # of [ default value, lower bound, upper bound ]-triples. In most cases, only one triple is used,
# # but the translation model has currently 5 features
# 
# # defaults for initial values and ranges are:
# 
# my $default_triples = {
#     # these basic models exist even if not specified, they are
#     # not associated with any model file
#     "w" => [ [ 0.0, -1.0, 1.0 ] ],  # word penalty
# };
# 
# my $additional_triples = {
#     # if the more lambda parameters for the weights are needed
#     # (due to additional tables) use the following values for them
#     "d"  => [ [ 1.0, 0.0, 2.0 ] ],  # lexicalized reordering model
#     "lm" => [ [ 1.0, 0.0, 2.0 ] ],  # language model
#     "g"  => [ [ 1.0, 0.0, 2.0 ],    # generation model
# 	      [ 1.0, 0.0, 2.0 ] ],
#     "tm" => [ [ 0.3, 0.0, 0.5 ],    # translation model
# 	      [ 0.2, 0.0, 0.5 ],
# 	      [ 0.3, 0.0, 0.5 ],
# 	      [ 0.2, 0.0, 0.5 ],
# 	      [ 0.0,-1.0, 1.0 ] ],  # ... last weight is phrase penalty
#     "lex"=> [ [ 0.1, 0.0, 0.2 ] ],  # global lexical model
#     "I"  => [ [ 0.0,-1.0, 1.0 ] ],  # input lattice scores
# };
#     # the following models (given by shortname) use same triplet
#     # for any number of lambdas, the number of the lambdas is determined
#     # by the ini file
# my $additional_tripes_loop = { map { ($_, 1) } qw/ d I / };



# moses.ini file uses FULL names for lambdas, while this training script
# internally (and on the command line) uses ABBR names.
my @ABBR_FULL_MAP = qw(d=weight-d lm=weight-l tm=weight-t w=weight-w
  g=weight-generation lex=weight-lex I=weight-i);
my %ABBR2FULL = map {split/=/,$_,2} @ABBR_FULL_MAP;
my %FULL2ABBR = map {my ($a, $b) = split/=/,$_,2; ($b, $a);} @ABBR_FULL_MAP;

# # We parse moses.ini to figure out how many weights do we need to optimize.
# # For this, we must know the correspondence between options defining files
# # for models and options assigning weights to these models.
# my $TABLECONFIG_ABBR_MAP = "ttable-file=tm lmodel-file=lm distortion-file=d generation-file=g global-lexical-file=lex link-param-count=I";
# my %TABLECONFIG2ABBR = map {split(/=/,$_,2)} split /\s+/, $TABLECONFIG_ABBR_MAP;
# 
# # There are weights that do not correspond to any input file, they just increase the total number of lambdas we optimize
# #my $extra_lambdas_for_model = {
# #  "w" => 1,  # word penalty
# #  "d" => 1,  # basic distortion
# #};

my $minimum_required_change_in_weights = 0.00001;
    # stop if no lambda changes more than this

my $verbose = 0;
my $usage = 0; # request for --help
my $___WORKING_DIR = "mert-work";
my $___DEV_F = undef; # required, input text to decode
my $___DEV_E = undef; # required, basename of files with references
my $___DECODER = undef; # required, pathname to the decoder executable
my $___CONFIG = undef; # required, pathname to startup ini file
my $___N_BEST_LIST_SIZE = 100;
my $queue_flags = "-hard";  # extra parameters for parallelizer
      # the -l ws0ssmt was relevant only to JHU 2006 workshop
my $___JOBS = undef; # if parallel, number of jobs to use (undef or 0 -> serial)
my $___DECODER_FLAGS = ""; # additional parametrs to pass to the decoder
my $continue = 0; # should we try to continue from the last saved step?
my $skip_decoder = 0; # and should we skip the first decoder run (assuming we got interrupted during mert)
my $___FILTER_PHRASE_TABLE = 1; # filter phrase table
my $___PREDICTABLE_SEEDS = 0;
my $___RANDOM_RESTARTS = 20;


# Parameter for effective reference length when computing BLEU score
# Default is to use shortest reference
# Use "--shortest" to use shortest reference length
# Use "--average" to use average reference length
# Use "--closest" to use closest reference length
# Only one between --shortest, --average and --closest can be set
# If more than one choice the defualt (--shortest) is used
my $___SHORTEST = 0;
my $___AVERAGE = 0;
my $___CLOSEST = 0;

# Use "--nocase" to compute case-insensitive scores
my $___NOCASE = 0;

# Use "--nonorm" to non normalize translation before computing scores
my $___NONORM = 0;

# set 0 if input type is text, set 1 if input type is confusion network
my $___INPUTTYPE = 0; 


my $mertdir = undef; # path to new mert directory
my $mertargs = undef; # args to pass through to mert
my $filtercmd = undef; # path to filter-model-given-input.pl
my $filterfile = undef;
my $qsubwrapper = undef;
my $moses_parallel_cmd = undef;
my $old_sge = 0; # assume sge<6.0
my $___CONFIG_ORIG = undef; # pathname to startup ini file before filtering
my $___ACTIVATE_FEATURES = undef; # comma-separated (or blank-separated) list of features to work on 
                                  # if undef work on all features
                                  # (others are fixed to the starting values)
my $___RANGES = undef;
my $prev_aggregate_nbl_size = -1; # number of previous step to consider when loading data (default =-1)
                                  # -1 means all previous, i.e. from iteration 1
                                  # 0 means no previous data, i.e. from actual iteration
                                  # 1 means 1 previous data , i.e. from the actual iteration and from the previous one
                                  # and so on 
my $maximum_iterations = 25;

use strict;
use Getopt::Long;
GetOptions(
  "working-dir=s" => \$___WORKING_DIR,
  "input=s" => \$___DEV_F,
  "inputtype=i" => \$___INPUTTYPE,
  "refs=s" => \$___DEV_E,
  "decoder=s" => \$___DECODER,
  "config=s" => \$___CONFIG,
  "nbest=i" => \$___N_BEST_LIST_SIZE,
  "queue-flags=s" => \$queue_flags,
  "jobs=i" => \$___JOBS,
  "decoder-flags=s" => \$___DECODER_FLAGS,
  "continue" => \$continue,
  "skip-decoder" => \$skip_decoder,
  "shortest" => \$___SHORTEST,
  "average" => \$___AVERAGE,
  "closest" => \$___CLOSEST,
  "nocase" => \$___NOCASE,
  "nonorm" => \$___NONORM,
  "help" => \$usage,
  "verbose" => \$verbose,
  "mertdir=s" => \$mertdir,
  "mertargs=s" => \$mertargs,
  "rootdir=s" => \$SCRIPTS_ROOTDIR,
  "filtercmd=s" => \$filtercmd, # allow to override the default location
  "filterfile=s" => \$filterfile, # input to filtering script (useful for lattices/confnets)
  "qsubwrapper=s" => \$qsubwrapper, # allow to override the default location
  "mosesparallelcmd=s" => \$moses_parallel_cmd, # allow to override the default location
  "old-sge" => \$old_sge, #passed to moses-parallel
  "filter-phrase-table!" => \$___FILTER_PHRASE_TABLE, # (dis)allow of phrase tables
  "random-restarts=i" => \$___RANDOM_RESTARTS, # number of random restarts
  "predictable-seeds" => \$___PREDICTABLE_SEEDS, # make random restarts deterministic
  "activate-features=s" => \$___ACTIVATE_FEATURES, #comma-separated (or blank-separated) list of features to work on (others are fixed to the starting values)
  "range=s@" => \$___RANGES,
  "prev-aggregate-nbestlist=i" => \$prev_aggregate_nbl_size, #number of previous step to consider when loading data (default =-1, i.e. all previous)
  "maximum-iterations=i" => \$maximum_iterations,
) or exit(1);

# the 4 required parameters can be supplied on the command line directly
# or using the --options
if (scalar @ARGV == 4) {
  # required parameters: input_file references_basename decoder_executable
  $___DEV_F = shift;
  $___DEV_E = shift;
  $___DECODER = shift;
  $___CONFIG = shift;
}

if ($usage || !defined $___DEV_F || !defined $___DEV_E || !defined $___DECODER || !defined $___CONFIG) {
  print STDERR "usage: $0 input-text references decoder-executable decoder.ini
Options:
  --working-dir=mert-dir ... where all the files are created
  --nbest=100            ... how big nbestlist to generate
  --jobs=N               ... set this to anything to run moses in parallel
  --mosesparallelcmd=STR ... use a different script instead of moses-parallel
  --queue-flags=STRING   ... anything you with to pass to qsub, eg.
                             '-l ws06osssmt=true'. The default is: '-hard'
                             To reset the parameters, please use 
                             --queue-flags=' '
                             (i.e. a space between the quotes).
  --decoder-flags=STRING ... extra parameters for the decoder
  --continue             ... continue from the last successful iteration
  --skip-decoder         ... skip the decoder run for the first time,
                             assuming that we got interrupted during
                             optimization
  --shortest --average --closest
                         ... Use shortest/average/closest reference length
                             as effective reference length (mutually exclusive)
  --nocase               ... Do not preserve case information; i.e.
                             case-insensitive evaluation (default is false).
  --nonorm               ... Do not use text normalization (flag is not active,
                             i.e. text is NOT normalized)
  --filtercmd=STRING     ... path to filter-model-given-input.pl
  --filterfile=STRING    ... path to alternative to input-text for filtering
                             model. useful for lattice decoding
  --rootdir=STRING       ... where do helpers reside (if not given explicitly)
  --mertdir=STRING       ... path to new mert implementation
  --mertargs=STRING      ... extra args for mert, eg. to specify scorer
  --scorenbestcmd=STRING ... path to score-nbest.py
  --old-sge              ... passed to parallelizers, assume Grid Engine < 6.0
  --inputtype=[0|1|2]    ... Handle different input types: (0 for text,
                             1 for confusion network, 2 for lattices,
                             default is 0)
  --no-filter-phrase-table ... disallow filtering of phrase tables
                              (useful if binary phrase tables are available)
  --random-restarts=INT  ... number of random restarts (default: 20)
  --predictable-seeds    ... provide predictable seeds to mert so that random
                             restarts are the same on every run
  --range=tm:0..1,-1..1  ... specify min and max value for some features
                             --range can be repeated as needed.
                             The order of the various --range specifications
                             is important only within a feature name.
                             E.g.:
                               --range=tm:0..1,-1..1 --range=tm:0..2
                             is identical to:
                               --range=tm:0..1,-1..1,0..2
                             but not to:
                               --range=tm:0..2 --range=tm:0..1,-1..1 
  --activate-features=STRING  ... comma-separated list of features to optimize,
                                  others are fixed to the starting values
                                  default: optimize all features
                                  example: tm_0,tm_4,d_0
  --prev-aggregate-nbestlist=INT ... number of previous step to consider when
                                     loading data (default = $prev_aggregate_nbl_size)
                                    -1 means all previous, i.e. from iteration 1
                                     0 means no previous data, i.e. only the
                                       current iteration
                                     N means this and N previous iterations

  --maximum-iterations=ITERS ... Maximum number of iterations. Default: $maximum_iterations
";
  exit 1;
}


# Check validity of input parameters and set defaults if needed

print STDERR "Using SCRIPTS_ROOTDIR: $SCRIPTS_ROOTDIR\n";

# path of script for filtering phrase tables and running the decoder
$filtercmd="$SCRIPTS_ROOTDIR/training/filter-model-given-input.pl" if !defined $filtercmd;

if ( ! -x $filtercmd && ! $___FILTER_PHRASE_TABLE) {
  print STDERR "Filtering command not found: $filtercmd.\n";
  print STDERR "Use --filtercmd=PATH to specify a valid one or --no-filter-phrase-table\n";
  exit 1;
}

$qsubwrapper="$SCRIPTS_ROOTDIR/generic/qsub-wrapper.pl" if !defined $qsubwrapper;

$moses_parallel_cmd = "$SCRIPTS_ROOTDIR/generic/moses-parallel.pl"
  if !defined $moses_parallel_cmd;



if (!defined $mertdir) {
  $mertdir = "$SCRIPTS_ROOTDIR/../mert";
  print STDERR "Assuming --mertdir=$mertdir\n";
}

my $mert_extract_cmd = "$mertdir/extractor";
my $mert_mert_cmd = "$mertdir/mert";

die "Not executable: $mert_extract_cmd" if ! -x $mert_extract_cmd;
die "Not executable: $mert_mert_cmd" if ! -x $mert_mert_cmd;

$mertargs = "" if !defined $mertargs;

my $scconfig = undef;
if ($mertargs =~ /\-\-scconfig\s+(.+?)(\s|$)/){
  $scconfig=$1;
  $scconfig =~ s/\,/ /g;
  $mertargs =~ s/\-\-scconfig\s+(.+?)(\s|$)//;
}

# handling reference lengh strategy
if (($___CLOSEST + $___AVERAGE + $___SHORTEST) > 1){
  die "You can specify just ONE reference length strategy (closest or shortest or average) not both\n";
}

if ($___SHORTEST){
  $scconfig .= " reflen:shortest";
}elsif ($___AVERAGE){
  $scconfig .= " reflen:average";
}elsif ($___CLOSEST){
  $scconfig .= " reflen:closest";
}

# handling case-insensitive flag
if ($___NOCASE) {
  $scconfig .= " case:false";
}else{
  $scconfig .= " case:true";
}
$scconfig =~ s/^\s+//;
$scconfig =~ s/\s+$//;
$scconfig =~ s/\s+/,/g;

$scconfig = "--scconfig $scconfig" if ($scconfig);

my $mert_extract_args=$mertargs;
$mert_extract_args .=" $scconfig";

my $mert_mert_args=$mertargs;
$mert_mert_args =~ s/\-+(binary|b)\b//;
$mert_mert_args .=" $scconfig";
if ($___ACTIVATE_FEATURES){ $mert_mert_args .=" -o \"$___ACTIVATE_FEATURES\""; }

my ($just_cmd_filtercmd,$x) = split(/ /,$filtercmd);
die "Not executable: $just_cmd_filtercmd" if ! -x $just_cmd_filtercmd;
die "Not executable: $moses_parallel_cmd" if defined $___JOBS && ! -x $moses_parallel_cmd;
die "Not executable: $qsubwrapper" if defined $___JOBS && ! -x $qsubwrapper;
die "Not executable: $___DECODER" if ! -x $___DECODER;


my $input_abs = ensure_full_path($___DEV_F);
die "File not found: $___DEV_F (interpreted as $input_abs)."
  if ! -e $input_abs;
$___DEV_F = $input_abs;


# Option to pass to qsubwrapper and moses-parallel
my $pass_old_sge = $old_sge ? "-old-sge" : "";

my $decoder_abs = ensure_full_path($___DECODER);
die "File not executable: $___DECODER (interpreted as $decoder_abs)."
  if ! -x $decoder_abs;
$___DECODER = $decoder_abs;


my $ref_abs = ensure_full_path($___DEV_E);
# check if English dev set (reference translations) exist and store a list of all references
my @references;
if (-e $ref_abs) {
  push @references, $ref_abs;
}
else {
  # if multiple file, get a full list of the files
    my $part = 0;
    while (-e $ref_abs.$part) {
        push @references, $ref_abs.$part;
        $part++;
    }
    die("Reference translations not found: $___DEV_E (interpreted as $ref_abs)") unless $part;
}

my $config_abs = ensure_full_path($___CONFIG);
die "File not found: $___CONFIG (interpreted as $config_abs)."
  if ! -e $config_abs;
$___CONFIG = $config_abs;

# moses should use our config
if ($___DECODER_FLAGS =~ /(^|\s)-(config|f) /
|| $___DECODER_FLAGS =~ /(^|\s)-(ttable-file|t) /
|| $___DECODER_FLAGS =~ /(^|\s)-(distortion-file) /
|| $___DECODER_FLAGS =~ /(^|\s)-(generation-file) /
|| $___DECODER_FLAGS =~ /(^|\s)-(lmodel-file) /
|| $___DECODER_FLAGS =~ /(^|\s)-(global-lexical-file) /
) {
  die "It is forbidden to supply any of -config, -ttable-file, -distortion-file, -generation-file or -lmodel-file in the --decoder-flags.\nPlease use only the --config option to give the config file that lists all the supplementary files.";
}

# as weights are normalized in the next steps (by cmert)
# normalize initial LAMBDAs, too
my $need_to_normalize = 1;




#store current directory and create the working directory (if needed)
my $cwd = `pawd 2>/dev/null`; 
if(!$cwd){$cwd = `pwd`;}
chomp($cwd);

mkpath($___WORKING_DIR);

{
# open local scope

#chdir to the working directory
chdir($___WORKING_DIR) or die "Can't chdir to $___WORKING_DIR";

# fixed file names
my $mert_outfile = "mert.out";
my $mert_logfile = "mert.log";
my $weights_in_file = "init.opt";
my $weights_out_file = "weights.txt";


# set start run
my $start_run = 1;
my $bestpoint = undef;
my $devbleu = undef;

my $prev_feature_file = undef;
my $prev_score_file = undef;


if ($___FILTER_PHRASE_TABLE) {
  my $outdir = "filtered";
  if (-e "$outdir/moses.ini") {
    print STDERR "Assuming the tables are already filtered, reusing $outdir/moses.ini\n";
  } else {
    # filter the phrase tables with respect to input, use --decoder-flags
    print STDERR "filtering the phrase tables... ".`date`;
    my $___FILTER_F  = $___DEV_F;
    $___FILTER_F = $filterfile if (defined $filterfile);
    my $cmd = "$filtercmd ./$outdir $___CONFIG $___FILTER_F";
    if (defined $___JOBS && $___JOBS > 0) {
      safesystem("$qsubwrapper $pass_old_sge -command='$cmd' -queue-parameter=\"$queue_flags\" -stdout=filterphrases.out -stderr=filterphrases.err" )
        or die "Failed to submit filtering of tables to the queue (via $qsubwrapper)";
    } else {
      safesystem($cmd) or die "Failed to filter the tables.";
    }
  }

  # make a backup copy of startup ini filepath
  $___CONFIG_ORIG = $___CONFIG;
  # the decoder should now use the filtered model
  $___CONFIG = "$outdir/moses.ini";
}
else{
  # do not filter phrase tables (useful if binary phrase tables are available)
  # use the original configuration file
  $___CONFIG_ORIG = $___CONFIG;
}


# we run moses to check validity of moses.ini and to obtain all the feature
# names
my $featlist = get_featlist_from_moses($___CONFIG);
$featlist = insert_ranges_to_featlist($featlist, $___RANGES);

# Mark which features are disabled:
if (defined $___ACTIVATE_FEATURES) {
  my %enabled = map { ($_, 1) } split /[, ]+/, $___ACTIVATE_FEATURES;
  my %cnt;
  for(my $i=0; $i<scalar(@{$featlist->{"names"}}); $i++) {
    my $name = $featlist->{"names"}->[$i];
    $cnt{$name} = 0 if !defined $cnt{$name};
    $featlist->{"enabled"}->[$i] = $enabled{$name."_".$cnt{$name}};
    $cnt{$name}++;
  }
} else {
  # all enabled
  for(my $i=0; $i<scalar(@{$featlist->{"names"}}); $i++) {
    $featlist->{"enabled"}->[$i] = 1;
  }
}

print STDERR "MERT starting values and ranges for random generation:\n";
for(my $i=0; $i<scalar(@{$featlist->{"names"}}); $i++) {
  my $name = $featlist->{"names"}->[$i];
  my $val = $featlist->{"values"}->[$i];
  my $min = $featlist->{"mins"}->[$i];
  my $max = $featlist->{"maxs"}->[$i];
  my $enabled = $featlist->{"enabled"}->[$i];
  printf STDERR "  %5s = %7.3f", $name, $val;
  if ($enabled) {
    printf STDERR " (%5.2f .. %5.2f)\n", $min, $max;
  } else {
    print STDERR " --- inactive, not optimized ---\n";
  }
}

if ($continue) {
  # getting the last finished step
  print STDERR "Trying to continue an interrupted optimization.\n";
  open IN, "finished_step.txt" or die "Failed to find the step number, failed to read finished_step.txt";
  my $step = <IN>;
  chomp $step;
  close IN;

  print STDERR "Last finished step is $step\n";

  # getting the first needed step
  my $firststep;
  if ($prev_aggregate_nbl_size==-1){
    $firststep=1;
  }
  else{
    $firststep=$step-$prev_aggregate_nbl_size+1;
    $firststep=($firststep>0)?$firststep:1;
  }

#checking if all needed data are available
  if ($firststep<=$step){
    print STDERR "First previous needed data index is $firststep\n";
    print STDERR "Checking whether all needed data (from step $firststep to step $step) are available\n";
    
    for (my $prevstep=$firststep; $prevstep<=$step;$prevstep++){
      print STDERR "Checking whether data of step $prevstep are available\n";
      if (! -e "run$prevstep.features.dat"){
	die "Can't start from step $step, because run$prevstep.features.dat was not found!";
      }else{
	if (defined $prev_feature_file){
	  $prev_feature_file = "${prev_feature_file},run$prevstep.features.dat";
	}
	else{
	  $prev_feature_file = "run$prevstep.features.dat";
	}
      }
      if (! -e "run$prevstep.scores.dat"){
	die "Can't start from step $step, because run$prevstep.scores.dat was not found!";
      }else{
	if (defined $prev_score_file){
	  $prev_score_file = "${prev_score_file},run$prevstep.scores.dat";
	}
	else{
	  $prev_score_file = "run$prevstep.scores.dat";
	}
      }
    }
    if (! -e "run$step.weights.txt"){
      die "Can't start from step $step, because run$step.weights.txt was not found!";
    }
    if (! -e "run$step.$mert_logfile"){
      die "Can't start from step $step, because run$step.$mert_logfile was not found!";
    }
    if (! -e "run$step.best$___N_BEST_LIST_SIZE.out.gz"){
      die "Can't start from step $step, because run$step.best$___N_BEST_LIST_SIZE.out.gz was not found!";
    }
    print STDERR "All needed data are available\n";

    print STDERR "Loading information from last step ($step)\n";
    open(IN,"run$step.$mert_logfile") or die "Can't open run$step.$mert_logfile";
    while (<IN>) {
      if (/Best point:\s*([\s\d\.\-e]+?)\s*=> ([\-\d\.]+)/) {
	$bestpoint = $1;
	$devbleu = $2;
	last;
      }
    }
    close IN;
    die "Failed to parse mert.log, missed Best point there."
      if !defined $bestpoint || !defined $devbleu;
    print "($step) BEST at $step $bestpoint => $devbleu at ".`date`;
    
    my @newweights = split /\s+/, $bestpoint;
    
    # Sanity check: order of lambdas must match
    sanity_check_order_of_lambdas($featlist,
      "gunzip -c < run$step.best$___N_BEST_LIST_SIZE.out.gz |");
    
    # update my cache of lambda values
    $featlist->{"values"} = \@newweights;
    
  }
  else{
    print STDERR "No previous data are needed\n";
  }

  $start_run = $step +1;
}

###### MERT MAIN LOOP

my $run=$start_run-1;

my $oldallsorted = undef;
my $allsorted = undef;

my $nbest_file=undef;

while(1) {
  $run++;
  if ($maximum_iterations && $run > $maximum_iterations) {
      print "Maximum number of iterations exceeded - stopping\n";
      last;
  }
  # run beamdecoder with option to output nbestlists
  # the end result should be (1) @NBEST_LIST, a list of lists; (2) @SCORE, a list of lists of lists

  print "run $run start at ".`date`;

  # In case something dies later, we might wish to have a copy
  create_config($___CONFIG, "./run$run.moses.ini", $featlist, $run, (defined$devbleu?$devbleu:"--not-estimated--"));


  # skip if the user wanted
  if (!$skip_decoder) {
      print "($run) run decoder to produce n-best lists\n";
      $nbest_file = run_decoder($featlist, $run, $need_to_normalize);
      $need_to_normalize = 0;
      safesystem("gzip -f $nbest_file") or die "Failed to gzip run*out";
      $nbest_file = $nbest_file.".gz";
  }
  else {
      $nbest_file="run$run.best$___N_BEST_LIST_SIZE.out.gz";
      print "skipped decoder run $run\n";
      $skip_decoder = 0;
      $need_to_normalize = 0;
  }



  # extract score statistics and features from the nbest lists
  print STDERR "Scoring the nbestlist.\n";

  my $base_feature_file = "features.dat";
  my $base_score_file = "scores.dat";
  my $feature_file = "run$run.${base_feature_file}";
  my $score_file = "run$run.${base_score_file}";

  my $cmd = "$mert_extract_cmd $mert_extract_args --scfile $score_file --ffile $feature_file -r ".join(",", @references)." -n $nbest_file";

  if (defined $___JOBS && $___JOBS > 0) {
    safesystem("$qsubwrapper $pass_old_sge -command='$cmd' -queue-parameter=\"$queue_flags\" -stdout=extract.out -stderr=extract.err" )
      or die "Failed to submit extraction to queue (via $qsubwrapper)";
  } else {
    safesystem("$cmd > extract.out 2> extract.err") or die "Failed to do extraction of statistics.";
  }

  # Create the initial weights file for mert: init.opt

  my @MIN = @{$featlist->{"mins"}};
  my @MAX = @{$featlist->{"maxs"}};
  my @CURR = @{$featlist->{"values"}};
  my @NAME = @{$featlist->{"names"}};
  
  open(OUT,"> $weights_in_file")
    or die "Can't write $weights_in_file (WD now $___WORKING_DIR)";
  print OUT join(" ", @CURR)."\n";
  print OUT join(" ", @MIN)."\n";  # this is where we could pass MINS
  print OUT join(" ", @MAX)."\n";  # this is where we could pass MAXS
  close(OUT);
  # print join(" ", @NAME)."\n";
  
  # make a backup copy labelled with this run number
  safesystem("\\cp -f $weights_in_file run$run.$weights_in_file") or die;

  my $DIM = scalar(@CURR); # number of lambdas

  # run mert
  $cmd = "$mert_mert_cmd -d $DIM $mert_mert_args -n $___RANDOM_RESTARTS";
  if ($___PREDICTABLE_SEEDS) {
      my $seed = $run * 1000;
      $cmd = $cmd." -r $seed";
  }

  if (defined $prev_feature_file) {
    $cmd = $cmd." --ffile $prev_feature_file,$feature_file";
  }
  else{
    $cmd = $cmd." --ffile $feature_file";
  }
  if (defined $prev_score_file) {
    $cmd = $cmd." --scfile $prev_score_file,$score_file";
  }
  else{
    $cmd = $cmd." --scfile $score_file";
  }

  $cmd = $cmd." --ifile run$run.$weights_in_file";

  if (defined $___JOBS && $___JOBS > 0) {
    safesystem("$qsubwrapper $pass_old_sge -command='$cmd' -stdout=$mert_outfile -stderr=$mert_logfile -queue-parameter=\"$queue_flags\"") or die "Failed to start mert (via qsubwrapper $qsubwrapper)";
  } else {
    safesystem("$cmd > $mert_outfile 2> $mert_logfile") or die "Failed to run mert";
  }
  die "Optimization failed, file $weights_out_file does not exist or is empty"
    if ! -s $weights_out_file;


 # backup copies
  safesystem ("\\cp -f extract.err run$run.extract.err") or die;
  safesystem ("\\cp -f extract.out run$run.extract.out") or die;
  safesystem ("\\cp -f $mert_outfile run$run.$mert_outfile") or die;
  safesystem ("\\cp -f $mert_logfile run$run.$mert_logfile") or die;
  safesystem ("touch $mert_logfile run$run.$mert_logfile") or die;
  safesystem ("\\cp -f $weights_out_file run$run.$weights_out_file") or die; # this one is needed for restarts, too

  print "run $run end at ".`date`;

  $bestpoint = undef;
  $devbleu = undef;
  open(IN,"run$run.$mert_logfile") or die "Can't open run$run.$mert_logfile";
  while (<IN>) {
    if (/Best point:\s*([\s\d\.\-e]+?)\s*=> ([\-\d\.]+)/) {
      $bestpoint = $1;
      $devbleu = $2;
      last;
    }
  }
  close IN;
  die "Failed to parse mert.log, missed Best point there."
    if !defined $bestpoint || !defined $devbleu;
  print "($run) BEST at $run: $bestpoint => $devbleu at ".`date`;

  # update my cache of lambda values
  my @newweights = split /\s+/, $bestpoint;

  $featlist->{"values"} = \@newweights;

  ## additional stopping criterion: weights have not changed
  my $shouldstop = 1;
  for(my $i=0; $i<@CURR; $i++) {
    die "Lost weight! mert reported fewer weights (@newweights) than we gave it (@CURR)"
      if !defined $newweights[$i];
    if (abs($CURR[$i] - $newweights[$i]) >= $minimum_required_change_in_weights) {
      $shouldstop = 0;
      last;
    }
  }

  open F, "> finished_step.txt" or die "Can't mark finished step";
  print F $run."\n";
  close F;


  if ($shouldstop) {
    print STDERR "None of the weights changed more than $minimum_required_change_in_weights. Stopping.\n";
    last;
  }

  my $firstrun;
  if ($prev_aggregate_nbl_size==-1){
    $firstrun=1;
  }
  else{
    $firstrun=$run-$prev_aggregate_nbl_size+1;
    $firstrun=($firstrun>0)?$firstrun:1;
  }
  print "loading data from $firstrun to $run (prev_aggregate_nbl_size=$prev_aggregate_nbl_size)\n";
  $prev_feature_file = undef;
  $prev_score_file = undef;
  for (my $i=$firstrun;$i<=$run;$i++){ 
    if (defined $prev_feature_file){
      $prev_feature_file = "${prev_feature_file},run${i}.${base_feature_file}";
    }
    else{
      $prev_feature_file = "run${i}.${base_feature_file}";
    }
    if (defined $prev_score_file){
      $prev_score_file = "${prev_score_file},run${i}.${base_score_file}";
    }
    else{
      $prev_score_file = "run${i}.${base_score_file}";
    }
  }
  print "loading data from $prev_feature_file\n" if defined($prev_feature_file);
  print "loading data from $prev_score_file\n" if defined($prev_score_file);
}
print "Training finished at ".`date`;

if (defined $allsorted){ safesystem ("\\rm -f $allsorted") or die; };

safesystem("\\cp -f $weights_in_file run$run.$weights_in_file") or die;
safesystem("\\cp -f $mert_logfile run$run.$mert_logfile") or die;

create_config($___CONFIG_ORIG, "./moses.ini", $featlist, $run, $devbleu);

# just to be sure that we have the really last finished step marked
open F, "> finished_step.txt" or die "Can't mark finished step";
print F $run."\n";
close F;


#chdir back to the original directory # useless, just to remind we were not there
chdir($cwd);

} # end of local scope

sub run_decoder {
    my ($featlist, $run, $need_to_normalize) = @_;
    my $filename_template = "run%d.best$___N_BEST_LIST_SIZE.out";
    my $filename = sprintf($filename_template, $run);
    
    # user-supplied parameters
    print "params = $___DECODER_FLAGS\n";

    # parameters to set all model weights (to override moses.ini)
    my @vals = @{$featlist->{"values"}};
    if ($need_to_normalize) {
      print STDERR "Normalizing lambdas: @vals\n";
      my $totlambda=0;
      grep($totlambda+=abs($_),@vals);
      grep($_/=$totlambda,@vals);
    }
    # moses now does not seem accept "-tm X -tm Y" but needs "-tm X Y"
    my %model_weights;
    for(my $i=0; $i<scalar(@{$featlist->{"names"}}); $i++) {
      my $name = $featlist->{"names"}->[$i];
      $model_weights{$name} = "-$name" if !defined $model_weights{$name};
      $model_weights{$name} .= sprintf " %.6f", $vals[$i];
    }
    my $decoder_config = join(" ", values %model_weights);
    print STDERR "DECODER_CFG = $decoder_config\n";
    print "decoder_config = $decoder_config\n";

    # run the decoder
    my $nBest_cmd = "-n-best-size $___N_BEST_LIST_SIZE";
    my $decoder_cmd;

    if (defined $___JOBS && $___JOBS > 0) {
      $decoder_cmd = "$moses_parallel_cmd $pass_old_sge -config $___CONFIG -inputtype $___INPUTTYPE -qsub-prefix mert$run -queue-parameters \"$queue_flags\" -decoder-parameters \"$___DECODER_FLAGS $decoder_config\" -n-best-list \"$filename $___N_BEST_LIST_SIZE\" -input-file $___DEV_F -jobs $___JOBS -decoder $___DECODER > run$run.out";
    } else {
      $decoder_cmd = "$___DECODER $___DECODER_FLAGS  -config $___CONFIG -inputtype $___INPUTTYPE $decoder_config -n-best-list $filename $___N_BEST_LIST_SIZE -input-file $___DEV_F > run$run.out";
    }

    safesystem($decoder_cmd) or die "The decoder died. CONFIG WAS $decoder_config \n";

    sanity_check_order_of_lambdas($featlist, $filename);
    return $filename;
}


sub insert_ranges_to_featlist {
  my $featlist = shift;
  my $ranges = shift;

  $ranges = [] if !defined $ranges;

  # first collect the ranges from options
  my $niceranges;
  foreach my $range (@$ranges) {
    my $name = undef;
    foreach my $namedpair (split /,/, $range) {
      if ($namedpair =~ /^(.*?):/) {
        $name = $1;
        $namedpair =~ s/^.*?://;
        die "Unrecognized name '$name' in --range=$range"
          if !defined $ABBR2FULL{$name};
      }
      my ($min, $max) = split /\.\./, $namedpair;
      die "Bad min '$min' in --range=$range" if $min !~ /^-?[0-9.]+$/;
      die "Bad max '$max' in --range=$range" if $min !~ /^-?[0-9.]+$/;
      die "No name given in --range=$range" if !defined $name;
      push @{$niceranges->{$name}}, [$min, $max];
    }
  }

  # now populate featlist
  my $seen = undef;
  for(my $i=0; $i<scalar(@{$featlist->{"names"}}); $i++) {
    my $name = $featlist->{"names"}->[$i];
    $seen->{$name} ++;
    my $min = 0.0;
    my $max = 1.0;
    if (defined $niceranges->{$name}) {
      my $minmax = shift @{$niceranges->{$name}};
      ($min, $max) = @$minmax if defined $minmax;
    }
    $featlist->{"mins"}->[$i] = $min;
    $featlist->{"maxs"}->[$i] = $max;
  }
  return $featlist;
}

sub sanity_check_order_of_lambdas {
  my $featlist = shift;
  my $filename_or_stream = shift;

  my @expected_lambdas = @{$featlist->{"names"}};
  my @got = get_order_of_scores_from_nbestlist($filename_or_stream);
  die "Mismatched lambdas. Decoder returned @got, we expected @expected_lambdas"
    if "@got" ne "@expected_lambdas";
}
    

sub get_featlist_from_moses {
  # run moses with the given config file and return the list of features and
  # their initial values
  my $configfn = shift;
  my $featlistfn = "./features.list";
  if (-e $featlistfn) {
    print STDERR "Using cached features list: $featlistfn\n";
  } else {
    print STDERR "Asking moses for feature names and values from $___CONFIG\n";
    my $cmd = "$___DECODER $___DECODER_FLAGS -config $configfn  -inputtype $___INPUTTYPE -show-weights > $featlistfn";
    safesystem($cmd) or die "Failed to run moses with the config $configfn";
  }

  # read feature list
  my @names = ();
  my @startvalues = ();
  open(INI,$featlistfn) or die "Can't read $featlistfn";
  my $nr = 0;
  my @errs = ();
  while (<INI>) {
    $nr++;
    chomp;
    my ($longname, $feature, $value) = split / /;
    push @errs, "$featlistfn:$nr:Bad initial value of $feature: $value\n"
      if $value !~ /^[+-]?[0-9.e]+$/;
    push @errs, "$featlistfn:$nr:Unknown feature '$feature', please add it to \@ABBR_FULL_MAP\n"
      if !defined $ABBR2FULL{$feature};
    push @names, $feature;
    push @startvalues, $value;
  }
  close INI;
  if (scalar @errs) {
    print STDERR join("", @errs);
    exit 1;
  }
  return {"names"=>\@names, "values"=>\@startvalues};
}


sub get_order_of_scores_from_nbestlist {
  # read the first line and interpret the ||| label: num num num label2: num ||| column in nbestlist
  # return the score labels in order
  my $fname_or_source = shift;
  # print STDERR "Peeking at the beginning of nbestlist to get order of scores: $fname_or_source\n";
  open IN, $fname_or_source or die "Failed to get order of scores from nbestlist '$fname_or_source'";
  my $line = <IN>;
  close IN;
  die "Line empty in nbestlist '$fname_or_source'" if !defined $line;
  my ($sent, $hypo, $scores, $total) = split /\|\|\|/, $line;
  $scores =~ s/^\s*|\s*$//g;
  die "No scores in line: $line" if $scores eq "";

  my @order = ();
  my $label = undef;
  foreach my $tok (split /\s+/, $scores) {
    if ($tok =~ /^([a-z][0-9a-z]*):/i) {
      $label = $1;
    } elsif ($tok =~ /^-?[-0-9.e]+$/) {
      # a score found, remember it
      die "Found a score but no label before it! Bad nbestlist '$fname_or_source'!"
        if !defined $label;
      push @order, $label;
    } else {
      die "Not a label, not a score '$tok'. Failed to parse the scores string: '$scores' of nbestlist '$fname_or_source'";
    }
  }
  print STDERR "The decoder returns the scores in this order: @order\n";
  return @order;
}

sub create_config {
    my $infn = shift; # source config
    my $outfn = shift; # where to save the config
    my $featlist = shift; # the lambdas we should write
    my $iteration = shift;  # just for verbosity
    my $bleu_achieved = shift; # just for verbosity

    my %P; # the hash of all parameters we wish to override

    # first convert the command line parameters to the hash
    { # ensure local scope of vars
	my $parameter=undef;
	print "Parsing --decoder-flags: |$___DECODER_FLAGS|\n";
        $___DECODER_FLAGS =~ s/^\s*|\s*$//;
        $___DECODER_FLAGS =~ s/\s+/ /;
	foreach (split(/ /,$___DECODER_FLAGS)) {
	    if (/^\-([^\d].*)$/) {
		$parameter = $1;
		$parameter = $ABBR2FULL{$parameter} if defined($ABBR2FULL{$parameter});
	    }
	    else {
                die "Found value with no -paramname before it: $_"
                  if !defined $parameter;
		push @{$P{$parameter}},$_;
	    }
	}
    }

    # First delete all weights params from the input, we're overwriting them.
    # Delete both short and long-named version.
    for(my $i=0; $i<scalar(@{$featlist->{"names"}}); $i++) {
      my $name = $featlist->{"names"}->[$i];
      delete($P{$name});
      delete($P{$ABBR2FULL{$name}});
    }

    # Convert weights to elements in P
    for(my $i=0; $i<scalar(@{$featlist->{"names"}}); $i++) {
      my $name = $featlist->{"names"}->[$i];
      my $val = $featlist->{"values"}->[$i];
      $name = defined $ABBR2FULL{$name} ? $ABBR2FULL{$name} : $name;
        # ensure long name
      push @{$P{$name}}, $val;
    }

    # create new moses.ini decoder config file by cloning and overriding the original one
    open(INI,$infn) or die "Can't read $infn";
    delete($P{"config"}); # never output 
    print "Saving new config to: $outfn\n";
    open(OUT,"> $outfn") or die "Can't write $outfn";
    print OUT "# MERT optimized configuration\n";
    print OUT "# decoder $___DECODER\n";
    print OUT "# BLEU $bleu_achieved on dev $___DEV_F\n";
    print OUT "# We were before running iteration $iteration\n";
    print OUT "# finished ".`date`;
    my $line = <INI>;
    while(1) {
	last unless $line;

	# skip until hit [parameter]
	if ($line !~ /^\[(.+)\]\s*$/) { 
	    $line = <INI>;
	    print OUT $line if $line =~ /^\#/ || $line =~ /^\s+$/;
	    next;
	}

	# parameter name
	my $parameter = $1;
	$parameter = $ABBR2FULL{$parameter} if defined($ABBR2FULL{$parameter});
	print OUT "[$parameter]\n";

	# change parameter, if new values
	if (defined($P{$parameter})) {
	    # write new values
	    foreach (@{$P{$parameter}}) {
		print OUT $_."\n";
	    }
	    delete($P{$parameter});
	    # skip until new parameter, only write comments
	    while($line = <INI>) {
		print OUT $line if $line =~ /^\#/ || $line =~ /^\s+$/;
		last if $line =~ /^\[/;
		last unless $line;
	    }
	    next;
	}
	
	# unchanged parameter, write old
	while($line = <INI>) {
	    last if $line =~ /^\[/;
	    print OUT $line;
	}
    }

    # write all additional parameters
    foreach my $parameter (keys %P) {
	print OUT "\n[$parameter]\n";
	foreach (@{$P{$parameter}}) {
	    print OUT $_."\n";
	}
    }

    close(INI);
    close(OUT);
    print STDERR "Saved: $outfn\n";
}

sub safesystem {
  print STDERR "Executing: @_\n";
  system(@_);
  if ($? == -1) {
      print STDERR "Failed to execute: @_\n  $!\n";
      exit(1);
  }
  elsif ($? & 127) {
      printf STDERR "Execution of: @_\n  died with signal %d, %s coredump\n",
          ($? & 127),  ($? & 128) ? 'with' : 'without';
      exit(1);
  }
  else {
    my $exitcode = $? >> 8;
    print STDERR "Exit code: $exitcode\n" if $exitcode;
    return ! $exitcode;
  }
}
sub ensure_full_path {
    my $PATH = shift;
$PATH =~ s/\/nfsmnt//;
    return $PATH if $PATH =~ /^\//;
    my $dir = `pawd 2>/dev/null`; 
    if(!$dir){$dir = `pwd`;}
    chomp($dir);
    $PATH = $dir."/".$PATH;
    $PATH =~ s/[\r\n]//g;
    $PATH =~ s/\/\.\//\//g;
    $PATH =~ s/\/+/\//g;
    my $sanity = 0;
    while($PATH =~ /\/\.\.\// && $sanity++<10) {
        $PATH =~ s/\/+/\//g;
        $PATH =~ s/\/[^\/]+\/\.\.\//\//g;
    }
    $PATH =~ s/\/[^\/]+\/\.\.$//;
    $PATH =~ s/\/+$//;
$PATH =~ s/\/nfsmnt//;
    return $PATH;
}





