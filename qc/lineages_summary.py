# Gathers seq-run_summary.csv files and merges with pangolin lineage table
# Takes 2 arguments:
# 1. Path to directory containing per-sequence-run summary.csv files
# 2. Path of pangolin lineage file


import pandas as pd
from sys import argv
import glob
import os

SAMPLE_NAME = "Sample"
SAMPLE_ID = "sample_id"
CONS_NAME = "consensus_seq_name"
MOD_CONS_NAME = "modded_consensus_seq_name"


# recreate un-reversable pangolin name munge;
# code pulled and very slightly modded from
# https://github.com/cov-lineages/pangolin/blob/
#  1763ac04da0dff41bd778cfa72f41a361457d81d/pangolin/command.py#L144-L147
def _perform_pangolin_name_munge(seq_name):
    mod_seq_name = seq_name.replace(' ', '_')
    if "," in mod_seq_name:
        mod_seq_name = mod_seq_name.replace(",", "_")
    return mod_seq_name


def merge_summaries(run_summaries_fp, run_summary_suffix):
    # Merge summaries with a single header
    summaries_pattern = os.path.join(run_summaries_fp,
                                     f"*{run_summary_suffix}")
    matching_fps = glob.glob(summaries_pattern)
    matching_dfs = []
    for fp in matching_fps:
        curr_df = pd.read_csv(fp, dtype=str)
        matching_dfs.append(curr_df)
    merged_summaries_df = pd.concat(matching_dfs)
    return merged_summaries_df


def expand_with_added_fa_names(merged_summaries_df, added_fa_names_fp):
    fas_col_name = "fasta_id"

    # read this in as a tsv (even though just one column) bc some of these
    # names have commas in them so can't read as csv ...
    added_fastq_ids_df = pd.read_csv(added_fa_names_fp, sep="\t", dtype=str)

    # make a column to hold the sample id; for these added ids, the sample
    # name is the same as the fas name (for now, until naming conventions are
    # nailed down; sorry, Yoshiki :( )
    added_fastq_ids_df[SAMPLE_ID] = added_fastq_ids_df[fas_col_name]
    # also copy it into "Sample" column for now, just so it has something there
    added_fastq_ids_df[SAMPLE_NAME] = added_fastq_ids_df[fas_col_name]

    # rename the "fasta_id" column "consensus_seq_name"
    added_fastq_ids_df.rename(
        columns={fas_col_name: CONS_NAME}, inplace=True)

    expanded_df = merged_summaries_df.merge(
        added_fastq_ids_df,
        left_on=[CONS_NAME, SAMPLE_NAME, SAMPLE_ID],
        right_on=[CONS_NAME, SAMPLE_NAME, SAMPLE_ID], how="outer")
    expanded_df.fillna('', inplace=True)

    # add a "modded_consensus_seq_name" col
    # by modifying the consensus name column contents according to
    # pangolin's irreversible munge rules
    expanded_df[MOD_CONS_NAME] = \
        expanded_df[CONS_NAME].apply(_perform_pangolin_name_munge)

    return expanded_df


def generate_metadata_df(expanded_summaries_df, lineage_df):
    # RIGHT merge expanded summaries with lineages (include ONLY lines
    # for samples that went through lineage calling)
    metadata_df = expanded_summaries_df.merge(
        lineage_df, left_on=MOD_CONS_NAME, right_on=MOD_CONS_NAME, how="right")

    # rearrange columns--want CONS_NAME as first column to match up
    # with the fas record names, which are used as the tree node names
    # in the tree file
    # shift column 'consensus_seq_name' to first position
    first_column = metadata_df.pop(CONS_NAME)
    metadata_df.insert(0, CONS_NAME, first_column)
    return metadata_df


def create_lineages_summary_and_metadata(arg_list):
    added_fa_names_fp = arg_list[1]
    run_summaries_fp = arg_list[2]
    run_summary_suffix = arg_list[3]
    lineage_fp = arg_list[4]
    out_summary_fp = arg_list[5]
    out_metadata_fp = arg_list[6]

    merged_summaries_df = merge_summaries(run_summaries_fp, run_summary_suffix)
    expanded_summaries_df = expand_with_added_fa_names(
        merged_summaries_df, added_fa_names_fp)
    expanded_summaries_copy_df = expanded_summaries_df.copy(deep=True)

    # Load pangolin file to a dataframe and
    # copy the "taxon" column into a new col named "modded_consensus_seq_name"
    lineage_df = pd.read_csv(lineage_fp, dtype=str)
    lineage_df[MOD_CONS_NAME] = lineage_df["taxon"]

    # outer merge expanded summaries with lineages (includes lines for
    # both samples that went through lineage calling and those that didn't)
    output_df = expanded_summaries_df.merge(
        lineage_df, left_on=MOD_CONS_NAME, right_on=MOD_CONS_NAME, how="outer")
    output_df.to_csv(out_summary_fp, index=False)

    # there *shouldn't* be any rows in the lineage that aren't in the
    # expanded summaries ... if there are, something is wrong.  Raise
    # an error (but *after* writing the output file, so we have some chance of
    # figuring out what went wrong).
    if len(output_df) != len(expanded_summaries_df):
        raise ValueError(f"Expected {len(expanded_summaries_df)} rows, "
                         f"got {len(output_df)}")

    # RIGHT merge expanded summaries with lineages (include ONLY lines
    # for samples that went through lineage calling because those are also
    # the only ones that go to tree building.)
    # NB that empress metadata files must be tsv
    metadata_df = generate_metadata_df(expanded_summaries_copy_df, lineage_df)
    metadata_df.to_csv(out_metadata_fp, sep='\t', index=False)


if __name__ == '__main__':
    argv = ["python lineages_summary.py",
            "/Users/amandabirmingham/Desktop/added_fa_names-1.txt",
            "/Users/amandabirmingham/Desktop/",
            "-summary.csv",
            "/Users/amandabirmingham/Desktop/2021-03-13_00-11-09.lineage_report.csv",
            "/Users/amandabirmingham/Desktop/qc-and-lin-test.csv",
            "/Users/amandabirmingham/Desktop/metadata-test.tsv"]
    create_lineages_summary_and_metadata(argv)
