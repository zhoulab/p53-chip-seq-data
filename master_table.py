import pandas as pd
from pandasql import sqldf
from optparse import OptionParser
from numpy import log10
from Bio import SeqIO


def anno_category(s):
    """Return annotation category from detailed annotation.

    Assumes each detailed annotation has only one category name
    unless one is followed by a parenthesis.
    If so, return the category before the parenthesis.
    """
    repeats = {'RNA', 'Simple_repeat', 'Satellite', 'SINE',
               'Low_complexity', 'LTR', 'LINE', 'DNA'}
    non_repeats = {'TSS', 'TTS', 'exon', "5' UTR", "3' UTR",
                   'CpG', 'intron', 'Intergenic', 'non-coding'}
    other = {'Other', 'Unknown'}
    lp_idx = s.find('(')
    if lp_idx > 0:
        s = s[:lp_idx]
    for cat in (repeats | non_repeats | other):
        if cat in s:
            return cat


def generate_master_table(options):
    # get peaks
    peaks = pd.read_table(options.merged_file,
                          header=None, names=("chr", "start", "end"))
    samples = pd.read_table(options.samples_file)
    samples.rename(columns={col: 'sample_' + col
                            for col in ('chr', 'start', 'end', 'length')},
                   inplace=True)

    # table DataFrame
    tbl = peaks
    merged_samples = sqldf("""SELECT *
                                FROM peaks AS p
                                JOIN samples AS s
                                     ON (s.sample_start >= p.start
                                         AND s.sample_end <= p.end)""", locals())
    grouped = merged_samples.groupby(['chr', 'start', 'end'])
    tbl['Sample Count'] = grouped.count()['Sample_Name'].values
    for sample_name in set(samples.Sample_Name):
        tbl[sample_name] = None

    for table_i, row in tbl.iterrows():
        print table_i,
        key = tuple(list(row.values)[:3])
        group = grouped.get_group(key)
        for i, s in enumerate(group["Sample_Name"]):
            if options.sample_col == 'macs':
                tbl.loc[table_i, s] = group["MACS_Score"].iloc[i]
            elif options.sample_col == 'fe':
                tbl.loc[table_i, s] = group["fold_enrichment"].iloc[i]

    anno = pd.read_table(options.anno_file)
    anno = anno[['Chr', 'Start', 'End',
                 'Detailed Annotation', 'Gene Name']].sort(['Chr', 'Start', 'End'])
    tbl['Detailed Annotation'] = anno['Detailed Annotation']
    tbl['Annotation Category'] = tbl['Detailed Annotation'].apply(anno_category)
    tbl['Gene Name'] = anno['Gene Name']

    # aggregate samples by regions
    grouped_samples = grouped.agg({'MACS_Score': max,
                                   'fold_enrichment': max}).reset_index()

    # aggregate matrices by regions
    mast_out = pd.read_table(options.mast_file)
    mast_out['matrix_score'] = -log10(mast_out['hit_p.value'])
    merged_mast = sqldf("""SELECT *, mo.ROWID AS matrix_id
                             FROM peaks AS p
                             JOIN mast_out AS mo
                                  ON (mo.hit_start >= p.start
                                      AND mo.hit_end <= p.end)""", locals())
    grouped2 = merged_mast.groupby(['chr', 'start', 'end'])
    # TODO: aggregate matrix_id
    grouped_mast = grouped2.agg({'matrix_score': max}).reset_index()

    table2 = sqldf("""   SELECT t.*,
                                gm.matrix_score,
                                gs.MACS_Score, gs.fold_enrichment
                           FROM tbl AS t
                      LEFT JOIN grouped_mast AS gm
                                ON (gm.chr = t.chr
                                    AND gm.start = t.start
                                    AND gm.end = t.end)
                      LEFT JOIN grouped_samples AS gs
                                ON (gs.chr = t.chr
                                    AND gs.start = t.start
                                    AND gs.end = t.end)""", locals())
    table2.rename(columns={'matrix_score': 'Max Matrix Score',
                           'MACS_Score': 'Max MACS Score',
                           'fold_enrichment': 'Max Fold Enrichment'},
                  inplace=True)

    table2['Repeat Count'] = [seq_record.seq.count('N') for seq_record
                              in SeqIO.parse(options.fasta_file, "fasta")]
    table2['Length'] = [len(seq_record) for seq_record
                        in SeqIO.parse(options.fasta_file, "fasta")]
    table2['Repeat Proportion'] = 1.0 * table2['Repeat Count'] / table2['Length']

    table2.to_csv(options.out_file, sep="\t", index=False)


if __name__ == "__main__":
    parser = OptionParser()
    parser.add_option('--merged_file',
                      help='BED file defining merged regions')
    parser.add_option('--samples_file',
                      help='concatenated samples BED file')
    parser.add_option('--mast_file',
                      help='matrix results file')
    parser.add_option('--anno_file',
                      help='annotation file for merged regions')
    parser.add_option('--fasta_file',
                      help='FASTA file for merged regions')
    parser.add_option('-o', '--out_file',
                      help='output filepath')
    parser.add_option('--sample_col', choices=['macs', 'fe'],
                      help='value for sample column')
    (options, args) = parser.parse_args()
    generate_master_table(options)
