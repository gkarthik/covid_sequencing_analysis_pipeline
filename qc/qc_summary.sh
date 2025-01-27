#!/bin/bash

PIPELINEDIR=/shared/workspace/software/covid_sequencing_analysis_pipeline
PHYLORESULTS=$S3DOWNLOAD/$SEQ_RUN/"$SEQ_RUN"_results/"$TIMESTAMP"_"$FQ"/"$SEQ_RUN"_phylogenetic_results
QCRESULTS=$S3DOWNLOAD/$SEQ_RUN/"$SEQ_RUN"_results/"$TIMESTAMP"_"$FQ"/"$SEQ_RUN"_quality_control
# Activate conda env covid1.2
ANACONDADIR=/shared/workspace/software/anaconda3/bin
source $ANACONDADIR/activate covid1.2
# clear workspace if node is being reused
rm -rf $WORKSPACE/*
mkdir -p $WORKSPACE/qc/fastqc

runQC () {

	aws s3 cp $S3DOWNLOAD/$SEQ_RUN/"$SEQ_RUN"_results/"$TIMESTAMP"_"$FQ"/"$SEQ_RUN"_samples/ $WORKSPACE/ \
		--quiet \
		--recursive \
		--exclude "*" \
		--include "*.variants.tsv" \
		--include "*.consensus.fa" \
		--include "*.depth.txt" \
		--include "*fastqc.zip" \
		--include "*.sorted.stats*" \
		--include "*.acceptance.tsv"

	# Zip files
	mv $WORKSPACE/*/*.variants.tsv $WORKSPACE/*/*.consensus.fa $WORKSPACE/*/*.depth.txt $WORKSPACE/*/*.acceptance.tsv $WORKSPACE
	cd $WORKSPACE && zip -9 "$SEQ_RUN"-variants.zip *.variants.tsv && zip -9 "$SEQ_RUN"-consensus.zip *.consensus.fa && zip -9 "$SEQ_RUN"-depth.zip *.depth.txt

	# summary figures and stats
	echo "Generating a violin plot of mapping depth across all samples and line plots of mapping depth per sample."
	python $PIPELINEDIR/qc/samtools_depth_plots.py $WORKSPACE/qc/"$SEQ_RUN"-depth_lineplot.pdf $WORKSPACE/qc/"$SEQ_RUN"-depth_violin.pdf $WORKSPACE/*.depth.txt
	# mv depth_violin.pdf $WORKSPACE/qc/"$SEQ_RUN"-depth_violin.pdf
	# mv depth_lineplot.pdf $WORKSPACE/qc/"$SEQ_RUN"-depth_lineplot.pdf
	echo "Summarizing consensus QC."
	python $PIPELINEDIR/qc/seq_run_acceptance.py $WORKSPACE $WORKSPACE/"$SEQ_RUN"-acceptance.tsv
	# mv $WORKSPACE/summary.acceptance.tsv $WORKSPACE/"$SEQ_RUN"-summary.acceptance.tsv

	# Multiqc
	echo "Configuring Multiqc"
	find $WORKSPACE -name "qualimapReport.html" | sort -n > $WORKSPACE/qc/qualimapReport_paths.txt
	for z in $WORKSPACE/*/fastqc/*fastqc.zip; do unzip -q $z -d $WORKSPACE/qc/fastqc; done
	find $WORKSPACE -name "fastqc_data.txt" | sort -n > $WORKSPACE/qc/fastqc_data_paths.txt
	python $PIPELINEDIR/qc/custom_gen_stats_multiqc.py $WORKSPACE/qc/qualimapReport_paths.txt $WORKSPACE/qc/fastqc_data_paths.txt $FQ $WORKSPACE/multiqc_custom_gen_stats.yaml
	cat $PIPELINEDIR/qc/covid_custom_config.yaml $WORKSPACE/multiqc_custom_gen_stats.yaml > $WORKSPACE/qc/"$SEQ_RUN"-custom_gen_stats_config.yaml
	multiqc --config $WORKSPACE/qc/"$SEQ_RUN"-custom_gen_stats_config.yaml --module qualimap --module custom_content $WORKSPACE

	# Make QC table
	python $PIPELINEDIR/qc/seq_run_summary.py $WORKSPACE/multiqc_data/multiqc_general_stats.txt $WORKSPACE/"$SEQ_RUN"-acceptance.tsv $WORKSPACE/"$SEQ_RUN"-summary.csv
	# mv $WORKSPACE/QCSummaryTable.csv $WORKSPACE/"$SEQ_RUN"-QCSummaryTable.csv

	# Concatenate all consensus files to a .fas file
	cat $WORKSPACE/*.consensus.fa > $WORKSPACE/"$SEQ_RUN".fas

    # Id only passing consensus files and write them to a *-passQC.fas file
    PASSING_CONS_FNAMES=$(python $PIPELINEDIR/qc/subset_csv.py $WORKSPACE/"$SEQ_RUN"-summary.csv not_na_cons_fnames $WORKSPACE)
    cat $PASSING_CONS_FNAMES > $WORKSPACE/"$SEQ_RUN"-passQC.fas

	# Id only consensus files failing acceptance because of the indel flag.
	# Write these to a *-indel_flagged.fas file and also create a *-summary.csv
	# file holding only the records for these sequences
	# INDEL_CONS_FNAMES=$(python $PIPELINEDIR/qc/subset_csv.py $WORKSPACE/"$SEQ_RUN"-summary.csv indel_flagged_cons_fnames $WORKSPACE)
	# cat $INDEL_CONS_FNAMES > $WORKSPACE/"$SEQ_RUN"-indel_flagged.fas
	# python $PIPELINEDIR/qc/subset_csv.py $WORKSPACE/"$SEQ_RUN"-summary.csv filtered_lines indels_flagged True $WORKSPACE/"$SEQ_RUN"-indel_flagged_qc_summary.csv

	# Upload Results
	echo "Uploading QC and summary results."
	# phylogenetic results folder
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-variants.zip $PHYLORESULTS/
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-consensus.zip $PHYLORESULTS/
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-depth.zip $PHYLORESULTS/
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-passQC.fas $PHYLORESULTS/
	aws s3 cp $WORKSPACE/"$SEQ_RUN".fas $PHYLORESULTS/
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-acceptance.tsv $PHYLORESULTS/

	# quality control folder
	aws s3 cp $WORKSPACE/multiqc_data/ $QCRESULTS/"$SEQ_RUN"_multiqc_data/ --recursive --quiet
	aws s3 cp $WORKSPACE/multiqc_report.html $QCRESULTS/"$SEQ_RUN"_multiqc_report.html
	aws s3 cp $WORKSPACE/qc/ $QCRESULTS/ --recursive --quiet
    aws s3 cp $WORKSPACE/"$SEQ_RUN"-summary.csv $QCRESULTS/
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-acceptance.tsv $QCRESULTS/

	# Manual review folder
	# aws s3 cp $WORKSPACE/"$SEQ_RUN"-indel_flagged.fas $S3DOWNLOAD/manual_review/
  #	aws s3 cp $WORKSPACE/"$SEQ_RUN"-indel_flagged_qc_summary.csv $S3DOWNLOAD/manual_review/

	# Tree building data
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-passQC.fas $S3DOWNLOAD/phylogeny/cumulative_data/consensus/
	aws s3 cp $WORKSPACE/"$SEQ_RUN".fas $S3DOWNLOAD/phylogeny/cumulative_data/consensus/
	# aws s3 cp $WORKSPACE/"$SEQ_RUN"-summary.acceptance.tsv s3://ucsd-ccbb-projects/2021/20210208_COVID_sequencing/tree_building/acceptance/
	aws s3 cp $WORKSPACE/"$SEQ_RUN"-summary.csv $S3DOWNLOAD/phylogeny/cumulative_data/qc_summary/
}

{ time ( runQC ) ; } > $WORKSPACE/qc/"$SEQ_RUN"-qc_summary.log 2>&1

aws s3 cp $WORKSPACE/qc/"$SEQ_RUN"-qc_summary.log $QCRESULTS/

