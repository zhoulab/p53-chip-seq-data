bed_dir := data/SampleBEDs
fe_dir := data/FEfiles
mast_dir := data/MAST

dm6_dir := /ufrc/zhou/share/genomes/dm6
dm6_genome_fasta := $(dm6_dir)/Sequence/WholeGenomeFasta/genome.fa
dm6_genome_phastcons := $(dm6_dir)/phastCons27way/dm6.27way.phastCons.bed


# BINDING DATASET VARIABLES/TARGETS

MINSAMPLES := 2
REP_THRESHOLD_TYPE := max
REP_CUTOFF := 0.1
N_NONBINDING_INTERVALS := 20

TEST_SIZE := 0.5

minsamples_suffix := minsamples_$(MINSAMPLES)
rep_cutoff_suffix := rep_$(REP_THRESHOLD_TYPE)$(REP_CUTOFF)
n_nonbinding_suffix := nonbinding_$(N_NONBINDING_INTERVALS)
all_suffixes := $(minsamples_suffix)__$(rep_cutoff_suffix)__$(n_nonbinding_suffix)

peaks_binding_merged_subset := etc/peaks_binding_merged_subset__$(minsamples_suffix)__$(rep_cutoff_suffix).txt
peaks_nonbinding := etc/peaks_nonbinding__$(rep_cutoff_suffix)__$(n_nonbinding_suffix).txt
peaks_all := etc/peaks_all__$(all_suffixes).txt
peaks_all_bed := etc/peaks_all__$(all_suffixes).bed
peaks_all_phastcons_bed := etc/peaks_all_phastcons__$(all_suffixes).bed

datafile_full := results/datafiles/peaks_merged_features__$(all_suffixes).txt
datafile_train := results/datafiles/peaks_merged_features_train__$(all_suffixes).txt
datafile_test := results/datafiles/peaks_merged_features_test__$(all_suffixes).txt

etc/peaks_binding_all_samples.txt: scripts/concat_sample_beds.py $(bed_dir)/*.bed $(fe_dir)/*.xls
	# un-merged ChIP-seq intervals from all samples
	# cols: chr/start/end/length/sample_name/MACS_score/FE_score
	python $< --bed_directory $(bed_dir) --fe_directory $(fe_dir) --ignore_chr chrM -o $@

etc/peaks_binding_merged_maxMACS.bed: etc/peaks_binding_all_samples.txt
	# merged ChIP-seq intervals from all samples with MACS score aggregated by max value
	# cols: chr/start/end/sample_count_distinct/max_MACS_score
	tail -n+2 $< | sort -k1,1 -k2,2n | bedtools merge -i - -c 5,6 -o count_distinct,max > $@

$(peaks_binding_merged_subset): scripts/binding_dataset/subset_binding_peaks.py etc/peaks_binding_merged_maxMACS.bed
	# etc/peaks_binding_merged_maxMACS.bed subsetted by # samples and repeat threshold
	# cols: chr/start/end/id/sample_count_distinct/max_MACS_score
	python $< --merged_bed etc/peaks_binding_merged_maxMACS.bed \
			  --minsamples $(MINSAMPLES) \
			  --rep_threshold_type $(REP_THRESHOLD_TYPE) \
			  --rep_cutoff $(REP_CUTOFF) \
			  --genome_fasta $(dm6_genome_fasta) \
			  -o $@

$(peaks_nonbinding): scripts/binding_dataset/generate_nonbinding_peaks.py $(peaks_binding_merged_subset)
	# generated nonbinding peaks with sample_count_distinct, max_MACS_score = 0
	# cols: chr/start/end/id/sample_count_distinct/max_MACS_score
	python $< --binding_peaks $(peaks_binding_merged_subset) \
			  --genome_fasta $(dm6_genome_fasta) \
			  --rep_threshold_type $(REP_THRESHOLD_TYPE) \
			  --rep_cutoff $(REP_CUTOFF) \
			  --num_intervals_per_side $(N_NONBINDING_INTERVALS) \
			  -o $@

$(peaks_all): $(peaks_binding_merged_subset) $(peaks_nonbinding)
	# all binding+nonbinding peaks (sorted)
	# cols: chr/start/end/id/sample_count_distinct/max_MACS_score
	(head -n1 $(peaks_binding_merged_subset); \
	 ((tail -n+2 $(peaks_binding_merged_subset); \
	   tail -n+2 $(peaks_nonbinding)) | sort -k1,1 -k2,2n)) > $@

$(peaks_all_bed): $(peaks_all)
	# peaks_all.txt without header
	# cols: chr/start/end
	cut -f1,2,3 $(peaks_all) | tail -n+2 > $@

$(peaks_all_phastcons_bed): $(peaks_all_bed) $(dm6_genome_phastcons)
	# peaks_all.bed with phastCon score column
	# cols: chr/start/end/phastCon_score
	bedmap --echo --delim "\t" --mean $(peaks_all_bed) $(dm6_genome_phastcons) > $@

$(datafile_full): scripts/binding_dataset/peak_features.py $(peaks_all) $(peaks_all_phastcons_bed) $(mast_dir) $(dm6_genome_fasta)
	# complete datafile with features
	python $< --peaks_all $(peaks_all) \
		      --peaks_all_phastcons $(peaks_all_phastcons_bed) \
			  --mast_dir $(mast_dir) \
			  --genome_fasta $(dm6_genome_fasta) \
			  -o $(datafile_full)

train_test_split: scripts/binding_dataset/peak_features_preprocess.py $(datafile_full)
	# generate train and test set files with automatic filenames
	python $< --data_file $(datafile_full) \
			  --test_size $(TEST_SIZE) \
			  --train_out $(datafile_train) \
			  --test_out $(datafile_test)


# MASTER TABLE VARIABLES/TARGETS

master_table_fe := results/datafiles/ChIP_peaks_master_table_fe.txt
master_table_macs := results/datafiles/ChIP_peaks_master_table_macs.txt

etc/peaks_binding_merged.bed: etc/peaks_binding_all_samples.txt
	# merged ChIP-seq intervals from all samples
	# cols: chr/start/end
	tail -n+2 $< | sort -k1,1 -k2,2n | bedtools merge -i - > $@

etc/peaks_binding_merged.anno: etc/peaks_binding_merged.bed
	# HOMER annotation of peaks_binding_merged.bed
	annotatePeaks.pl $< dm6 > $@

etc/peaks_binding_merged.fa: etc/peaks_binding_merged.bed
	# FASTA sequences for peaks_binding_merged.bed
	homerTools extract $< $(dm6_genome_fasta) -mask -fa > $@

etc/ChIP_peaks_master_table_melted.txt: scripts/master_table/master_table.py etc/peaks_binding_merged.bed etc/peaks_binding_all_samples.txt etc/peaks_binding_merged.fa etc/peaks_binding_merged.anno
	# master table with one row per sample
	python $< --merged_file etc/peaks_binding_merged.bed \
			  --samples_file etc/peaks_binding_all_samples.txt \
			  --fasta_file etc/peaks_binding_merged.fa \
			  --anno_file etc/peaks_binding_merged.anno \
			  -o $@

results/datafiles/ChIP_peaks_master_table_fe.txt: scripts/master_table/pivot_master_table.py etc/ChIP_peaks_master_table_melted.txt
	# master table FE scores in sample columns
	python $< --master_table etc/ChIP_peaks_master_table_melted.txt -o $@ --score fe

results/datafiles/ChIP_peaks_master_table_macs.txt: scripts/master_table/pivot_master_table.py etc/ChIP_peaks_master_table_melted.txt
	# master table MACS scores in sample columns
	python $< --master_table etc/ChIP_peaks_master_table_melted.txt -o $@ --score macs
