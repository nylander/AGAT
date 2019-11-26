#!/usr/bin/env perl

use strict;
use warnings;
use POSIX qw(strftime);
use List::MoreUtils  qw(natatime);;
use Carp;
use Getopt::Long;
use Pod::Usage;
use Bio::DB::Fasta;
use Bio::Tools::CodonTable;
use Clone 'clone';
use AGAT::Omniscient;

my $header = get_agat_header();
my $start_id = 1;
my $stop_id = 1;

my $opt_file=undef;
my $file_fasta=undef;
my $codon_table_id=1;
my $opt_output=undef;
my $verbose=undef;
my $opt_help = 0;

my @copyARGV=@ARGV;
if ( !GetOptions( 'i|g|gff=s' => \$opt_file,
                  "fasta|fa|f=s" => \$file_fasta,
                  "table|codon|ct=i" => \$codon_table_id,
                  'o|out|output=s' => \$opt_output,
                  'v!' => \$verbose,
                  'h|help!'         => \$opt_help ) )
{
    pod2usage( { -message => 'Failed to parse command line',
                 -verbose => 1,
                 -exitval => 1 } );
}

# Print Help and exit
if ($opt_help) {
    pod2usage( { -verbose => 99,
                 -exitval => 0,
                 -message => "$header\n" } );
}

if(! $opt_file or ! $file_fasta ) {
    pod2usage( {
           -message => "$header\nMust specify at least 2 parameters:\nA gff file (--gff) and a fasta file (--fasta) \n",
           -verbose => 0,
           -exitval => 1 } );
}

# #######################
# # START Manage Option #
# #######################

my $gffout;
if ($opt_output) {
  open(my $fh, '>', $opt_output) or die "Could not open file '$opt_output' $!";
  $gffout= Bio::Tools::GFF->new(-fh => $fh, -gff_version => 3 );
  }
else{
  $gffout = Bio::Tools::GFF->new(-fh => \*STDOUT, -gff_version => 3);
}

$codon_table_id = get_proper_codon_table($codon_table_id);
print "Codon table ".$codon_table_id." in use. You can change it using --table option.\n";
my $codon_table = Bio::Tools::CodonTable->new( -id => $codon_table_id);
# #####################################
# # END Manage OPTION
# #####################################



                                                      #######################
                                                      #        MAIN         #
#                     >>>>>>>>>>>>>>>>>>>>>>>>>       #######################       <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

#PART 1
###################################
# Read input gff3 files one by one and save value in hash of list


######################
### Parse GFF input #
my ($hash_omniscient, $hash_mRNAGeneLink) = slurp_gff3_file_JD({ input => $opt_file
                                                            });
print("Parsing Finished\n\n");
### END Parse GFF input #
#########################

####################
# index the genome #
my $db = Bio::DB::Fasta->new($file_fasta);
print ("Genome fasta parsed\n");

my $counter_start_missing = 0;
my $counter_start_added = 0;
my $counter_end_missing = 0;
my $counter_end_added = 0;

######################
### Parse GFF input #
# get nb of each feature in omniscient;
foreach my $tag_l2 (sort keys %{$hash_omniscient->{'level2'}}){
  foreach my $id_l1 (sort keys %{$hash_omniscient->{'level2'}{$tag_l2}}){
    foreach my $feature_l2 ( @{$hash_omniscient->{'level2'}{$tag_l2}{$id_l1}} ){

      # get level2 id
      my $id_level2 = lc($feature_l2->_tag_value('ID'));

      ##############################
      #If it's a mRNA = have CDS. #
      if ( exists ($hash_omniscient->{'level3'}{'cds'}{$id_level2} ) ){

        ##############
        # Manage CDS #
        my @cds_feature_list = sort {$a->start <=> $b->start} @{$hash_omniscient->{'level3'}{'cds'}{$id_level2}}; # be sure that list is sorted
        my $cds_dna_seq = concatenate_feature_list(\@cds_feature_list);
        print "sequence: $cds_dna_seq\n" if ($verbose);
        #create the cds object
        my $cds_obj = Bio::Seq->new(-seq => $cds_dna_seq, -alphabet => 'dna' );
        #Reverse the object depending on strand
        my $strand="+";
        if ($feature_l2->strand == -1 or $feature_l2->strand eq "-"){
          $cds_obj = $cds_obj->revcom();
          $strand = "-";
          print "feature on minus strand\n" if ($verbose);
        }

        #-------------------------
        #       START CASE
        #-------------------------
        if ( exists ($hash_omniscient->{'level3'}{'start_codon'}{$id_level2} ) ){
          print "start_codon already exists for $id_level2\n" if ($verbose);
        }
        else{

          my $first_codon = substr( $cds_obj->seq, 0, 3 );
          print "first_codon = $first_codon \n" if ($verbose);

          if ($codon_table->is_start_codon($first_codon)) {
            $counter_start_added++;
            print "first_codon is a start codon \n" if ($verbose);
            # create start feature
            my $start_feature = clone($cds_feature_list[0]);
            $start_feature->primary_tag('start_codon');
            my $ID='start_added-'.$start_id;
            $start_id++;
            create_or_replace_tag($start_feature,'ID', $ID); #modify ID to replace by parent val


            if($strand eq "+"){
              #set start position of the start codon
              $start_feature->start($cds_feature_list[0]->start());

              #set stop position of the start codon
              my $step=3;
              my $cpt=0;
              my $size = $cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              while($size < 3){

                my $start_feature_new = clone( $start_feature );
                $start_feature_new->end($cds_feature_list[$cpt]->start()+$size-1);
                my $ID='start_added-'.$start_id;
                $start_id++;
                create_or_replace_tag($start_feature_new,'ID', $ID); #modify ID to replace by parent val
                push @{$hash_omniscient->{'level3'}{'start_codon'}{$id_level2}}, $start_feature_new;

                $cpt++;
                $step-=$size;
                $start_feature->start($cds_feature_list[$cpt]->start());
                $size += $size + $cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              }
              $start_feature->end($cds_feature_list[$cpt]->start()+$step-1);
            }
            else{
              #set start position of the start codon
              $start_feature->end($cds_feature_list[$#cds_feature_list]->end());

              #set stop position of the start codon
              my $step=3;
              my $cpt=$#cds_feature_list;
              my $size=$cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              while($size < 3){

                my $start_feature_new = clone( $start_feature );
                $start_feature_new->start($cds_feature_list[$cpt]->end()-$size+1);
                my $ID='start_added-'.$start_id;
                $start_id++;
                create_or_replace_tag($start_feature_new,'ID', $ID); #modify ID to replace by parent val
                push @{$hash_omniscient->{'level3'}{'start_codon'}{$id_level2}}, $start_feature_new;

                $cpt--;
                $step-=$size;
                $start_feature->end($cds_feature_list[$cpt]->end());
                $size += $size + $cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              }
              $start_feature->start($cds_feature_list[$cpt]->end()-$step+1);
            }
            push @{$hash_omniscient->{'level3'}{'start_codon'}{$id_level2}}, $start_feature;
          }
          else{
            $counter_start_missing++;
          }
        }

        #-------------------------
        #       STOP CASE
        #-------------------------
        if ( exists ($hash_omniscient->{'level3'}{'stop_codon'}{$id_level2} ) ){
          print "stop_codon already exists for $id_level2\n" if ($verbose);
        }
        else{
          my $last_codon = substr( $cds_obj->seq, -3 );
          print "last_codon = $last_codon \n" if ($verbose);

          if ( $codon_table->is_ter_codon( $last_codon )){
            $counter_end_added++;
            print "last codon is a stop codon \n" if ($verbose);
            # create stop feature
            my $stop_feature = clone($cds_feature_list[0]);
            $stop_feature->primary_tag('stop_codon');
            my $ID='stop_added-'.$stop_id;
            $stop_id++;
            create_or_replace_tag($stop_feature,'ID', $ID); #modify ID to replace by parent value

            if($strand eq "+"){

              # set start position of the stop codon
              $stop_feature->end($cds_feature_list[$#cds_feature_list]->end());

              #set stop position of the stop codon
              my $step=3;
              my $cpt=$#cds_feature_list;
              my $size=$cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              while($size < 3){

                my $stop_feature_new = clone( $stop_feature );
                $stop_feature_new->start($cds_feature_list[$cpt]->end()-$size+1);
                my $ID='start_added-'.$start_id;
                $start_id++;
                create_or_replace_tag($stop_feature_new,'ID', $ID); #modify ID to replace by parent val
                push @{$hash_omniscient->{'level3'}{'stop_codon'}{$id_level2}}, $stop_feature_new;

                $cpt--;
                $step-=$size;
                $stop_feature->end($cds_feature_list[$cpt]->end());
                $size += $size + $cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              }
              #print $cds_feature_list[$cpt]->end()."\n";
              $stop_feature->start($cds_feature_list[$cpt]->end()-$step+1);
            }
            else{
              #set start position of the stop codon
              $stop_feature->start($cds_feature_list[0]->start());

              #set stop position of the stop codon
              my $step=3;
              my $cpt=0;
              my $size = $cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              while($size < 3){

                my $stop_feature_new = clone( $stop_feature );
                $stop_feature_new->end($cds_feature_list[$cpt]->start()+$size-1);
                my $ID='start_added-'.$start_id;
                $start_id++;
                create_or_replace_tag($stop_feature_new,'ID', $ID); #modify ID to replace by parent val
                push @{$hash_omniscient->{'level3'}{'stop_codon'}{$id_level2}}, $stop_feature_new;

                $cpt++;
                $step-=$size;
                $stop_feature->start($cds_feature_list[$cpt]->start());
                $size += $size + $cds_feature_list[$cpt]->end()-$cds_feature_list[$cpt]->start()+1;
              }
              $stop_feature->end($cds_feature_list[$cpt]->start()+$step-1);
            }
            push @{$hash_omniscient->{'level3'}{'stop_codon'}{$id_level2}}, $stop_feature;
          }
          else{
            $counter_end_missing++;
          }
        }
      }
    }
  }
}

print_omniscient($hash_omniscient, $gffout); #print gene modified
print "$counter_start_added start codon added and $counter_start_missing CDS do not start by a start codon\n";
print "$counter_end_added stop codon added and $counter_end_missing CDS do not end by a stop codon \n";
print "bye bye\n";

      #########################
      ######### END ###########
      #########################

#######################################################################################################################
        ####################
         #     methods    #
          ################
           ##############
            ############
             ##########
              ########
               ######
                ####
                 ##

sub concatenate_feature_list{

  my ($feature_list) = @_;

  my $seq = "";
  foreach my $feature (@$feature_list) {
    my $start=$feature->start();
    my $end=$feature->end();
    my $seqid=$feature->seq_id();
    $seq .= $db->seq( $seqid, $start, $end );
  }
   return $seq;
}

__END__
EXAMPLE NORMAL
##gff-version 3
Pcoprophilum_scaf_9 . contig  1 1302582 . . . ID=Pcoprophilum_scaf_9;Name=Pcoprophilum_scaf_9
Pcoprophilum_scaf_9 maker gene  189352  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.0
Pcoprophilum_scaf_9 maker mRNA  189352  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1;_AED=0.00;_eAED=0.00;_QI=398|1|1|1|0.5|0.33|3|343|825
Pcoprophilum_scaf_9 maker exon  189352  189520  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:exon:96;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker exon  189643  189922  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:exon:97;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker exon  189978  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:exon:98;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker five_prime_UTR  189352  189520  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:five_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker five_prime_UTR  189643  189871  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:five_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker CDS 189872  189922  . + 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker CDS 189978  192404  . + 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker three_prime_UTR 192405  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:three_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker gene  197438  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.3
Pcoprophilum_scaf_9 maker mRNA  197438  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1;_AED=0.00;_eAED=0.00;_QI=208|1|1|1|1|1|2|259|211
Pcoprophilum_scaf_9 maker exon  197438  198116  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:exon:141;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker exon  198291  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:exon:140;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker five_prime_UTR  198507  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:five_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker CDS 198291  198506  . - 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker CDS 197697  198116  . - 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker three_prime_UTR 197438  197696  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:three_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
EXAMPLE WITH SPREADED START AND STOP
##gff-version 3
Pcoprophilum_scaf_9 maker gene  189352  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.0
Pcoprophilum_scaf_9 maker mRNA  189352  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1;_AED=0.00;_eAED=0.00;_QI=398|1|1|1|0.5|0.33|3|343|825
Pcoprophilum_scaf_9 maker exon  189352  189520  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:exon:96;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker exon  189643  189922  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:exon:97;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker exon  189978  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:exon:98;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker five_prime_UTR  189352  189520  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:five_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker five_prime_UTR  189643  189871  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:five_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker CDS 189872  189873  . + 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker CDS 189874  189922  . + 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker CDS 189978  192402  . + 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker CDS 192403  192404  . + 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker three_prime_UTR 192405  192747  . + . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1:three_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.0-mRNA-1
Pcoprophilum_scaf_9 maker gene  197438  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.3
Pcoprophilum_scaf_9 maker mRNA  197438  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3;Name=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1;_AED=0.00;_eAED=0.00;_QI=208|1|1|1|1|1|2|259|211
Pcoprophilum_scaf_9 maker exon  197438  198116  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:exon:141;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker exon  198291  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:exon:140;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker five_prime_UTR  198507  198714  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:five_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker CDS 198505  198506  . - 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker CDS 198291  198504  . - 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker CDS 197699  198116  . - 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker CDS 197697  197698  . - 0 ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:cds;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1
Pcoprophilum_scaf_9 maker three_prime_UTR 197438  197696  . - . ID=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1:three_prime_utr;Parent=genemark-Pcoprophilum_scaf_9-processed-gene-2.3-mRNA-1


=head1 NAME

agat_sp_add_start_and_stop.pl.pl

=head1 DESCRIPTION

The script adds start and stop codons when a CDS feature exists.
The script looks at the nucleotide sequence and checks the presence of start and stop codons.
The script works even if the start or stop codon are split over several CDS features.

=head1 SYNOPSIS

    agat_sp_add_start_and_stop.pl.pl --gff infile.gff --fasta genome.fa --out outfile.gff
    agat_sp_add_start_and_stop.pl.pl --help

=head1 OPTIONS

=over 8

=item B<--gff>, B<-i> or B<-g>

Input GTF/GFF file.

=item B<--fasta>, B<--fa> or B<-f>

Input fasta file. Needed to check that CDS sequences start by start codon and stop by stop codon.

=item B<--ct>, B<--codon> or B<--table>

Codon table to use. 1 By default.

=item  B<--out>, B<--output> or B<-o>

Output gff file updated

=item B<-v>

Verbose for debugging purpose.

=item B<--help> or B<-h>

Display this helpful text.

=back

=head1 FEEDBACK

=head2 Did you find a bug?

Do not hesitate to report bugs to help us keep track of the bugs and their
resolution. Please use the GitHub issue tracking system available at this
address:

            https://github.com/NBISweden/AGAT/issues

 Ensure that the bug was not already reported by searching under Issues.
 If you're unable to find an (open) issue addressing the problem, open a new one.
 Try as much as possible to include in the issue when relevant:
 - a clear description,
 - as much relevant information as possible,
 - the command used,
 - a data sample,
 - an explanation of the expected behaviour that is not occurring.

=head2 Do you want to contribute?

You are very welcome, visit this address for the Contributing guidelines:
https://github.com/NBISweden/AGAT/blob/master/CONTRIBUTING.md

=cut

AUTHOR - Jacques Dainat
