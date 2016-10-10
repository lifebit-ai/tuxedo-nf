/*
 * Copyright (c) 2016, Centre for Genomic Regulation (CRG) and the authors.
 *
 *   This file is part of 'Tuxedo-NF'.
 *
 *   Tuxedo-NF is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   Tuxedo-NF is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with Tuxedo-NF.  If not, see <http://www.gnu.org/licenses/>.
 */

/* 
 * Main Tuxedo-NF pipeline script
 *
 * @authors
 * Evan Floden <evanfloden@gmail.com> 
 */

log.info "T U X E D O - N F  ~  version 0.1"
log.info "====================================="
log.info "reads                  : ${params.reads}"
log.info "genome                 : ${params.genome}"
log.info "index                  : ${params.index}"
log.info "phenotype info         : ${params.pheno}"               
log.info "annotation             : ${params.annotation}"
log.info "run index              : ${params.run_index}"
log.info "use SRA                : ${params.use_sra}"
log.info "SRA ids                : ${params.sra_ids}"
log.info "output                 : ${params.output}"
log.info "\n"

/*
 * Input parameters validation
 */

genome_file                   = file(params.genome)
annotation_file               = file(params.annotation) 
pheno_file                    = file(params.pheno)
index_file                    = file(params.index)
index_file1                   = index_file + ".1.ht2"
index_name                    = index_file.getFileName()
index_dir                     = index_file.getParent()
sra_ids_list                  = params.sra_ids.tokenize(",") 

/*
 * validate input files
 */
if( !genome_file.exists() ) exit 1, "Missing genome file: ${genome_file}"

if( !annotation_file.exists() ) exit 1, "Missing annotation file: ${annotation_file}"

/*
 * Create a channel for read files 
 */
 
Channel
    .fromFilePairs( params.reads, size: -1 , flat: true)
    .ifEmpty { error "Cannot find any reads matching: ${params.seqs}" }
    .set { read_files } 



/*
 * Create a channel for SRA IDs
 */

Channel
    .from( sra_ids_list )
    .set { sra_read_ids }


/*
 * Check index files if required
 */
if( !params.run_index ) {
    if ( !index_file1.exists() ) {
        exit 1, "Missing genome index file: ${index_file1}"
    }
}
     

// GENOME INDEXING
// ===============

if (params.run_index) {
    process genome_index {
        input:
        file genome_file

        output:
        file "index_dir" into genome_index

        script:
        //
        // HISAT2 genome index
        //
        """
        hisat2-build ${genome_file} genome_index
        mkdir index_dir
        mv genome_index* index_dir/.
        """
    }
}
else {
    process premade_index {
        input:
        file index_dir
        val index_name

        output:
        file "index_dir" into genome_index

        script:
        //
        // Premade HISAT2 genome index
        //
        """
        mkdir index_dir
        cp ${index_dir}/${index_name}.*.ht2 index_dir/.
        """
    }
}    



if (params.use_sra) {
    process sra_mapping {
        tag "sra reads: $sra_id"

        input:
        file index_dir from genome_index.first()
        val(sra_id) from sra_read_ids

        output:
        set val(sra_id), file("${sra_id}.sam") into hisat2_sams

        script:
        //
        // HISAT2 mapper using NCBI SRA Tools
        //
        """
        hisat2 -x ${index_dir}/genome_index --sra-acc ${sra_id} -S ${sra_id}.sam
        """
    }
}
else {
    process mapping {
        tag "reads: $name"

        input:
        file index_dir from genome_index.first()
        set val(name), file(reads) from read_files

        output:
        set val(name), file("${name}.sam") into hisat2_sams

        script:
        //
        // HISAT2 mapper
        //
        def single = reads instanceof Path
        if( single ) {
            """
            hisat2 -x ${index_dir}/genome_index -U ${reads[0]} -S ${name}.sam

            """
        }
        else {
            """
            hisat2 -x ${index_dir}/genome_index -1 ${reads[0]} -2 ${reads[1]} -S ${name}.sam
            """
        }
    }
}


process sam2bam {
    tag "sam2bam: $name"

    input:
    set val(name), file(sam) from hisat2_sams

    output:
    set val("${name}"), file("${name}.bam") into hisat2_bams

    script:
    //
    // SAM to sorted BAM files
    //
    """
    
    samtools view -S -b ${sam} | samtools sort -o ${name}.bam -    

    """
}


hisat2_bams.into { hisat2_bams1; hisat2_bams2 } 

process stringtie_assemble_transcripts {
    tag "stringtie assemble transcripts: $name"

    input:
    set val(name), file(bam) from hisat2_bams1
    file annotation_file

    output:
    file("${name}.gtf") into hisat2_transcripts

    script:
    //
    // Assemble Transcripts per sample
    //
    """
    
    stringtie -p ${task.cpus} -G ${annotation_file} -o ${name}.gtf -l ${name} ${bam}

    """
}   


hisat2_transcripts.into { hisat2_transcripts1; hisat2_transcripts2 }
hisat2_transcripts1
  .collectFile () { file ->  ['gtf_filenames.txt', file.name + '\n' ] }
  .set { GTF_filenames }

process merge_stringtie_transcripts {
    tag "merge stringtie transcripts"

    input:
    file merge_list from GTF_filenames
    file gtfs from hisat2_transcripts2.toList()
    file annotation_file

    output:
    file("stringtie_merged.gtf") into merged_transcripts

    script:
    //
    // Merge all stringtie transcripts
    //
    """
    stringtie --merge  -p ${task.cpus}  -G ${annotation_file} -o stringtie_merged.gtf  ${merge_list}
    """
}



process transcript_abundance {
    tag "reads: $name"

    input:
    set val(name), file(bam) from hisat2_bams2
    file merged_transcript_file from merged_transcripts.first()

    output:
    file("${name}") into ballgown_data

    script:
    //
    // Estimate abundances of merged transcripts in each sample
    //
    """
    stringtie -e -B -p ${task.cpus} -G ${merged_transcript_file} -o ${name}/${name}_abundance.gtf ${bam}

    """
}

	
process ballgown {
    tag "ballgown"

    input:
    file pheno_file
    file ballgown_dir from ballgown_data.toList()

    output:
    file("chrX_genes_results.csv") into sig_genes

    shell:
    //
    // Merge all stringtie transcripts
    //
    '''
    #!/usr/bin/env Rscript
 
    pheno_data_file <- "!{pheno_file}"

    library(ballgown)
    library(RSkittleBrewer)
    library(genefilter)
    library(dplyr)
    library(devtools)

    pheno_data <- read.csv(pheno_data_file)

    bg_chrX <- ballgown(dataDir = ".", samplePattern="ERR", pData=pheno_data)

    bg_chrX_filt <- subset(bg_chrX, "rowVars(texpr(bg_chrX)) > 1", genomesubset=TRUE)

    results_transcripts <-  stattest(bg_chrX_filt, feature='transcript', covariate='sex',
                            adjustvars=c('population'), getFC=TRUE, meas='FPKM')

    results_genes <-  stattest(bg_chrX_filt, feature='gene', covariate='sex',
                      adjustvars=c('population'), getFC=TRUE, meas='FPKM')

    results_transcripts <- data.frame(geneNames=ballgown::geneNames(bg_chrX_filt),
                           geneIDs=ballgown::geneIDs(bg_chrX_filt), results_transcripts)

    results_transcripts <- arrange(results_transcripts, pval)
    results_genes <-  arrange(results_genes, pval)

    write.csv(results_transcripts, "chrX_transcripts_results.csv", row.names=FALSE)
    write.csv(results_genes, "chrX_genes_results.csv", row.names=FALSE)

    '''
}


