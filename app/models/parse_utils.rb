class ParseUtils

  # parse a 10X gene-barcode matrix file triplet (input matrix must be sorted by gene indices)
  def self.cell_ranger_expression_parse(study, user, matrix_study_file, genes_study_file, barcodes_study_file, opts={})
    begin
      start_time = Time.now
      # localize files
      Rails.logger.info "#{Time.now}: Parsing 10X CellRanger source data files for #{study.name}"
      study.make_data_dir
      Rails.logger.info "#{Time.now}: Localizing output files & creating study file entries from 10X CellRanger source data for #{study.name}"

      # localize files if necessary, otherwise open newly uploaded files. check to make sure a local copy doesn't already exists
      # as we may be uploading files piecemeal from upload wizard

      if File.exists?(matrix_study_file.upload.path) || File.exists?(Rails.root.join(study.data_dir, matrix_study_file.download_location))
        matrix_content_type = matrix_study_file.determine_content_type
        if matrix_content_type == 'application/gzip'
          Rails.logger.info "#{Time.now}: Parsing #{matrix_study_file.name}:#{matrix_study_file.id} as application/gzip"
          matrix_file = Zlib::GzipReader.open(matrix_study_file.upload.path)
        else
          Rails.logger.info "#{Time.now}: Parsing #{matrix_study_file.name}:#{matrix_study_file.id} as text/plain"
          matrix_file = File.open(matrix_study_file.upload.path, 'rb')
        end
      else
        matrix_file = Study.firecloud_client.execute_gcloud_method(:download_workspace_file, study.firecloud_project,
                                                                   study.firecloud_workspace, matrix_study_file.bucket_location,
                                                                   study.data_store_path, verify: :none)
      end

      if File.exists?(genes_study_file.upload.path) || File.exists?(Rails.root.join(study.data_dir, genes_study_file.download_location))
        genes_content_type = genes_study_file.determine_content_type
        if genes_content_type == 'application/gzip'
          Rails.logger.info "#{Time.now}: Parsing #{genes_study_file.name}:#{genes_study_file.id} as application/gzip"
          genes_file = Zlib::GzipReader.open(genes_study_file.upload.path)
        else
          Rails.logger.info "#{Time.now}: Parsing #{genes_study_file.name}:#{genes_study_file.id} as text/plain"
          genes_file = File.open(genes_study_file.upload.path, 'rb')
        end
      else
        genes_file = Study.firecloud_client.execute_gcloud_method(:download_workspace_file, study.firecloud_project,
                                                                  study.firecloud_workspace, genes_study_file.bucket_location,
                                                                  study.data_store_path, verify: :none)
      end
      if File.exists?(barcodes_study_file.upload.path) || File.exists?(Rails.root.join(study.data_dir, barcodes_study_file.download_location))
        barcodes_content_type = barcodes_study_file.determine_content_type
        if barcodes_content_type == 'application/gzip'
          Rails.logger.info "#{Time.now}: Parsing #{barcodes_study_file.name}:#{barcodes_study_file.id} as application/gzip"
          barcodes_file = Zlib::GzipReader.open(barcodes_study_file.upload.path)
        else
          Rails.logger.info "#{Time.now}: Parsing #{barcodes_study_file.name}:#{barcodes_study_file.id} as text/plain"
          barcodes_file = File.open(barcodes_study_file.upload.path, 'rb')
        end
      else
        barcodes_file = Study.firecloud_client.execute_gcloud_method(:download_workspace_file, study.firecloud_project,
                                                                     study.firecloud_workspace, barcodes_study_file.bucket_location,
                                                                     study.data_store_path, verify: :none)
      end

      # next, check if this is a re-parse job, in which case we need to remove all existing entries first
      if opts[:reparse]
        Gene.where(study_id: study.id, study_file_id: matrix_study_file.id).delete_all
        DataArray.where(study_id: study.id, study_file_id: matrix_study_file.id).delete_all
        matrix_study_file.invalidate_cache_by_file_type
      end

      # process the genes file to concatenate gene names and IDs together (for differentiating entries with duplicate names)
      raw_genes = genes_file.readlines.map(&:strip)
      genes = []
      raw_genes.each do |row|
        gene_id, gene_name = row.split.map(&:strip)
        genes << "#{gene_name} (#{gene_id})"
      end

      # read barcodes file
      barcodes = barcodes_file.readlines.map(&:strip)

      # close files
      genes_file.close
      barcodes_file.close

      # validate that barcodes list does not have any repeated values
      existing_cells = study.all_expression_matrix_cells
      uniques = barcodes - existing_cells

      unless uniques.size == barcodes.size
        repeats = barcodes - uniques
        raise StandardError, "You have re-used the following cell names that were found in another expression matrix in your study (cell names must be unique across all expression matrices): #{repeats.join(', ')}"
      end

      # open matrix file and read contents
      Rails.logger.info "#{Time.now}: Reading gene/barcode/matrix file contents for #{study.name}"
      m_header_1 = matrix_file.readline.split.map(&:strip)
      valid_headers = %w(%%MatrixMarket matrix coordinate)
      unless m_header_1.first == valid_headers.first && m_header_1[1] == valid_headers[1] && m_header_1[2] == valid_headers[2]
        raise StandardError, "Your input matrix is not a Matrix Market Coordinate Matrix (header validation failed).  The first line should read: #{valid_headers.join}, but found #{m_header_1}"
      end

      scores_header = matrix_file.readline.strip
      while scores_header.start_with?('%')
        # discard empty comment lines
        scores_header = matrix_file.readline.strip
      end

      # containers for holding data yet to be saved
      @genes = []
      @data_arrays = []
      @count = 0
      @child_count = 0

      # read coordinate matrix and begin assigning data.  process the first line as normal to set up local variables in
      # order to loop on
      Rails.logger.info "#{Time.now}: Creating new gene & data_array records from 10X CellRanger source data for #{study.name}"

      scores = []
      cells = []
      line = matrix_file.readline.strip
      last_line = "line: #{matrix_file.lineno}: #{line}"
      gene_idx, barcode_idx, expression_score = read_coordinate_matrix(line)
      last_gene_idx = gene_idx
      gene_name = genes[gene_idx]
      barcode = barcodes[barcode_idx]
      current_gene = Gene.new(study_id: study.id, name: gene_name, searchable_name: gene_name.downcase, study_file_id: matrix_study_file.id)
      @genes << current_gene.attributes
      while !matrix_file.eof?
        if last_gene_idx == gene_idx
          cells << barcode
          scores << expression_score
          if !matrix_file.eof?
            line = matrix_file.readline.strip
            if line.strip.blank?
              break # would be the end of the file (hopefully)
            else
              last_line = "line: #{matrix_file.lineno}: #{line}"
              gene_idx, barcode_idx, expression_score = read_coordinate_matrix(line)
              gene_name = genes[gene_idx]
              barcode = barcodes[barcode_idx]
            end
          else
            break # we've hit the end of the file
          end
        else
          # we need to validate that the file is sorted correctly.  if our gene index has gone down from what it was before,
          # then we must abort and throw an error as the parse will not complete properly.  we will have all the genes,
          # but not all of the expression data
          if gene_idx < last_gene_idx
            Rails.logger.error "Error in parsing #{matrix_study_file.bucket_location} in #{study.name}: incorrect sort order; #{gene_idx + 1} is less than #{last_gene_idx + 1} at line #{matrix_file.lineno}"
            error_message = "Your input matrix is not sorted in the correct order.  The data must be sorted by gene index first, then barcode index: #{gene_idx + 1} is less than #{last_gene_idx + 1} at #{matrix_file.lineno}"
            raise StandardError, error_message
          end
          # create data_arrays and move to the next gene
          create_data_arrays(cells, matrix_study_file, 'cells', current_gene, @data_arrays)
          create_data_arrays(scores, matrix_study_file, 'expression', current_gene, @data_arrays)

          # reset containers
          cells = []
          scores = []
          gene_name = genes[gene_idx]
          current_gene = Gene.new(study_id: study.id, name: gene_name, searchable_name: gene_name.downcase, study_file_id: matrix_study_file.id)
          @genes << current_gene.attributes
          last_gene_idx = gene_idx # we only set this when we know the gene_idx has changed from last_gene_idx
          # batch insert records in groups of 1000
          if @data_arrays.size >= 1000
            Gene.create(@genes) # genes must be saved first, otherwise the linear data polymorphic association is invalid and will cause a parse fail
            @count += @genes.size
            Rails.logger.info "#{Time.now}: Processed #{@count} expressed genes from 10X CellRanger source data for #{study.name}"
            @genes = []
            DataArray.create(@data_arrays)
            @child_count += @data_arrays.size
            Rails.logger.info "#{Time.now}: Processed #{@child_count} child data arrays from 10X CellRanger source data for #{study.name}"
            @data_arrays = []
          end
        end
      end
      # write last batch of data.  we need to append the very last two values and make sure there's not a new gene to create
      # from the very last line
      if last_gene_idx != gene_idx
        create_data_arrays(cells, matrix_study_file, 'cells', current_gene, @data_arrays)
        create_data_arrays(scores, matrix_study_file, 'expression', current_gene, @data_arrays)
        cells = []
        scores = []
        gene_name = genes[gene_idx]
        current_gene = Gene.new(study_id: study.id, name: gene_name, searchable_name: gene_name.downcase, study_file_id: matrix_study_file.id)
        @genes << current_gene.attributes
      end
      barcode = barcodes[barcode_idx]
      cells << barcode
      scores << expression_score
      create_data_arrays(cells, matrix_study_file, 'cells', current_gene, @data_arrays)
      create_data_arrays(scores, matrix_study_file, 'expression', current_gene, @data_arrays)

      # close file and clean up
      matrix_file.close

      # create last records
      Gene.create(@genes)
      @count += @genes.size
      Rails.logger.info "#{Time.now}: Processed #{@count} expressed genes from 10X CellRanger source data for #{study.name}"
      DataArray.create(@data_arrays)
      @child_count += @data_arrays.size
      Rails.logger.info "#{Time.now}: Processed #{@child_count} child data arrays from 10X CellRanger source data for #{study.name}"
      # create array of known cells for this expression matrix
      barcodes.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
        known_cells = study.data_arrays.build(name: "#{matrix_study_file.name} Cells", cluster_name: matrix_study_file.name,
                                              array_type: 'cells', array_index: index + 1, values: slice,
                                              study_file_id: matrix_study_file.id, study_id: study.id)
        known_cells.save
      end

      # now we have to create empty gene records for all the non-significant genes
      # reset the count as we'll get an accurate total count from the length of the genes list
      @count = 0
      other_genes = []
      other_genes_count = 0
      genes.each do |gene|
        other_genes << Gene.new(study_id: study.id, name: gene, searchable_name: gene.downcase, study_file_id: matrix_study_file.id).attributes
        other_genes_count += 1
        if other_genes.size % 1000 == 0
          Rails.logger.info "#{Time.now}: creating #{other_genes_count} non-expressed gene records in #{study.name}"
          Gene.create(other_genes)
          @count += other_genes.size
          other_genes = []
        end
      end
      # process last batch
      Rails.logger.info "#{Time.now}: creating #{other_genes_count} non-expressed gene records in #{study.name}"
      Gene.create(other_genes)
      @count += other_genes.size

      # finish up
      matrix_study_file.update(parse_status: 'parsed')
      genes_study_file.update(parse_status: 'parsed')
      barcodes_study_file.update(parse_status: 'parsed')

      # set gene count
      study.set_gene_count

      # set the default expression label if the user supplied one
      if !study.has_expression_label? && !matrix_study_file.y_axis_label.blank?
        Rails.logger.info "#{Time.now}: Setting default expression label in #{study.name} to '#{matrix_study_file.y_axis_label}'"
        opts = study.default_options
        study.update!(default_options: opts.merge(expression_label: matrix_study_file.y_axis_label))
      end

      # set initialized to true if possible
      if study.cluster_groups.any? && study.cell_metadata.any? && !study.initialized?
        Rails.logger.info "#{Time.now}: initializing #{study.name}"
        study.update!(initialized: true)
        Rails.logger.info "#{Time.now}: #{study.name} successfully initialized"
      end

      end_time = Time.now
      time = (end_time - start_time).divmod 60.0
      @message = []
      @message << "#{Time.now}: #{study.name} 10X CellRanger expression data parse completed!"
      @message << "Gene-level entries created: #{@count}"
      @message << "Total Time: #{time.first} minutes, #{time.last} seconds"
      Rails.logger.info @message.join("\n")
      begin
        SingleCellMailer.notify_user_parse_complete(user.email, "10X CellRanger expression data has completed parsing", @message).deliver_now
      rescue => e
        Rails.logger.error "#{Time.now}: Unable to deliver email: #{e.message}"
      end

      # determine what to do with local files
      unless opts[:skip_upload] == true
        upload_or_remove_study_file(matrix_study_file, study)
        upload_or_remove_study_file(genes_study_file, study)
        upload_or_remove_study_file(barcodes_study_file, study)
      end

      # finished, so return true
      true
    rescue => e
      # error has occurred, so clean up records and remove file
      Gene.where(study_id: study.id, study_file_id: matrix_study_file.id).delete_all
      DataArray.where(study_id: study.id, study_file_id: matrix_study_file.id).delete_all
      # clean up files
      matrix_study_file.remove_local_copy
      genes_study_file.remove_local_copy
      barcodes_study_file.remove_local_copy
      matrix_study_file.destroy
      genes_study_file.destroy
      barcodes_study_file.destroy
      error_message = e.message
      Rails.logger.error "#{Time.now}: #{error_message}, #{last_line}"
      SingleCellMailer.notify_user_parse_fail(user.email, "10X CellRanger expression data in #{study.name} parse has failed", error_message).deliver_now
      false
    end
  end

  private

  # read a single line of a coordinate matrix and return parsed indices and expression value
  def self.read_coordinate_matrix(line)
    raw_gene_idx, raw_barcode_idx, raw_expression_score = line.split.map(&:strip)
    gene_idx = raw_gene_idx.to_i - 1 # since arrays are zero based, we need to offset by 1
    barcode_idx = raw_barcode_idx.to_i - 1 # since arrays are zero based, we need to offset by 1
    expression_score = raw_expression_score.to_f.round(3) # only keep 3 significant digits
    [gene_idx, barcode_idx, expression_score]
  end

  # slice up arrays of barcodes and expression scores and create data arrays, storing them in a container for saving later
  def self.create_data_arrays(source_data, study_file, data_array_type, parent_gene, data_arrays_container)
    data_array_name = data_array_type == 'cells' ? parent_gene.cell_key : parent_gene.score_key
    source_data.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
      array = DataArray.new(name: data_array_name, cluster_name: study_file.name, array_type: data_array_type,
                                 array_index: index + 1, study_file_id: study_file.id, values: slice,
                                 linear_data_type: 'Gene', linear_data_id: parent_gene.id, study_id: parent_gene.study_id)
      data_arrays_container << array.attributes
    end
  end

  # determine if local files need to be pushed to GCS bucket, or if they can be removed safely
  def self.upload_or_remove_study_file(study_file, study)
    Rails.logger.info "#{Time.now}: determining upload status of #{study_file.file_type}: #{study_file.bucket_location}:#{study_file.id}"
    # now that parsing is complete, we can move file into storage bucket and delete local (unless we downloaded from FireCloud to begin with)
    # rather than relying on opts[:local], actually check if the file is already in the GCS bucket
    remote = Study.firecloud_client.get_workspace_file(study.firecloud_project, study.firecloud_workspace, study_file.bucket_location)
    if remote.nil?
      begin
        Rails.logger.info "#{Time.now}: preparing to upload expression file: #{study_file.bucket_location}:#{study_file.id} to FireCloud"
        study.send_to_firecloud(study_file)
      rescue => e
        Rails.logger.info "#{Time.now}: Expression file: #{study_file.bucket_location}:#{study_file.id} failed to upload to FireCloud due to #{e.message}"
        SingleCellMailer.notify_admin_upload_fail(study_file, e.message).deliver_now
      end
    else
      # we have the file in FireCloud already, so just delete it
      begin
        Rails.logger.info "#{Time.now}: found remote version of #{study_file.bucket_location}: #{remote.name} (#{remote.generation})"
        run_at = 15.seconds.from_now
        Delayed::Job.enqueue(UploadCleanupJob.new(study, study_file), run_at: run_at)
        Rails.logger.info "#{Time.now}: cleanup job for #{study_file.bucket_location}:#{study_file.id} scheduled for #{run_at}"
      rescue => e
        # we don't really care if the delete fails, we can always manually remove it later as the file is in FireCloud already
        Rails.logger.error "#{Time.now}: Could not delete #{study_file.bucket_location}:#{study_file.id} in study #{self.name}; aborting"
        SingleCellMailer.admin_notification('Local file deletion failed', nil, "The file at #{Rails.root.join(study.data_store_path, study_file.download_location)} failed to clean up after parsing, please remove.").deliver_now
      end
    end
  end
end