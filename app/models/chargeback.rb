class Chargeback < ActsAsArModel
  VIRTUAL_COL_USES = {
    "v_derived_cpu_total_cores_used" => "cpu_usage_rate_average"
  }

  def self.build_results_for_report_chargeback(options)
    _log.info("Calculating chargeback costs...")

    tz = Metric::Helper.get_time_zone(options[:ext_options])
    # TODO: Support time profiles via options[:ext_options][:time_profile]

    interval = options[:interval] || "daily"
    cb = new

    options[:ext_options] ||= {}

    if @options[:groupby_tag]
      @tag_hash = Classification.hash_all_by_type_and_name[@options[:groupby_tag]][:entry]
    end

    base_rollup = MetricRollup.includes(
      :resource           => [:hardware, :tenant],
      :parent_host        => :tags,
      :parent_ems_cluster => :tags,
      :parent_storage     => :tags,
      :parent_ems         => :tags)
                              .select(*Metric::BASE_COLS).order("resource_id, timestamp")
    perf_cols = MetricRollup.attribute_names
    rate_cols = ChargebackRate.where(:default => true).flat_map do |rate|
      rate.chargeback_rate_details.map(&:metric).select { |metric| perf_cols.include?(metric.to_s) }
    end
    rate_cols.map! { |x| VIRTUAL_COL_USES.include?(x) ? VIRTUAL_COL_USES[x] : x }.flatten!
    base_rollup = base_rollup.select(*rate_cols)

    timerange = get_report_time_range(options, interval, tz)
    data = {}

    timerange.step_value(1.day).each_cons(2) do |query_start_time, query_end_time|
      recs = base_rollup.where(:timestamp => query_start_time...query_end_time, :capture_interval_name => "hourly")
      recs = where_clause(recs, options)
      recs = Metric::Helper.remove_duplicate_timestamps(recs)
      _log.info("Found #{recs.length} records for time range #{[query_start_time, query_end_time].inspect}")

      unless recs.empty?
        recs.each do |perf|
          next if perf.resource.nil?
          key, extra_fields = key_and_fields(perf, interval, tz)
          data[key] ||= extra_fields

          rates_to_apply = cb.get_rates(perf)
          chargeback_rates = data[key]["chargeback_rates"].split(', ') + rates_to_apply.collect(&:description)
          data[key]["chargeback_rates"] = chargeback_rates.uniq.join(', ')
          calculate_costs(perf, data[key], rates_to_apply)
        end
      end
    end
    _log.info("Calculating chargeback costs...Complete")

    [data.map { |r| new(r.last) }]
  end

  def self.key_and_fields(metric_rollup_record, interval, tz)
    ts_key = get_group_key_ts(metric_rollup_record, interval, tz)

    key, extra_fields = if @options[:groupby_tag].present?
                          get_tag_keys_and_fields(metric_rollup_record, ts_key)
                        else
                          get_keys_and_extra_fields(metric_rollup_record, ts_key)
                        end

    [key, date_fields(metric_rollup_record, interval, tz).merge(extra_fields)]
  end

  def self.date_fields(metric_rollup_record, interval, tz)
    start_ts, end_ts, display_range = get_time_range(metric_rollup_record, interval, tz)

    {
      'start_date'       => start_ts,
      'end_date'         => end_ts,
      'display_range'    => display_range,
      'interval_name'    => interval,
      'chargeback_rates' => ''
    }
  end

  def self.get_tag_keys_and_fields(perf, ts_key)
    tag = perf.tag_names.split("|").select { |x| x.starts_with?(@options[:groupby_tag]) }.first # 'department/*'
    tag = tag.split('/').second unless tag.blank? # 'department/finance' -> 'finance'
    classification = @tag_hash[tag]
    classification_id = classification.present? ? classification.id : 'none'
    key = "#{classification_id}_#{ts_key}"
    extra_fields = { "tag_name" => classification.present? ? classification.description : _('<Empty>') }
    [key, extra_fields]
  end

  def get_rates(perf)
    @rates ||= {}
    @enterprise ||= MiqEnterprise.my_enterprise

    tags = perf.tag_names.split("|").reject { |n| n.starts_with?("folder_path_") }.sort.join("|")
    keys = [tags, perf.parent_host_id, perf.parent_ems_cluster_id, perf.parent_storage_id, perf.parent_ems_id]
    tenant_resource = perf.resource.try(:tenant)
    keys.push(tenant_resource.id) unless tenant_resource.nil?
    key = keys.join("_")
    return @rates[key] if @rates.key?(key)

    tag_list = perf.tag_names.split("|").inject([]) { |arr, t| arr << "vm/tag/managed/#{t}"; arr }

    parents = [perf.parent_host, perf.parent_ems_cluster, perf.parent_storage, perf.parent_ems, @enterprise].compact
    parents.push(tenant_resource) unless tenant_resource.nil?

    @rates[key] = ChargebackRate.get_assigned_for_target(perf.resource, :tag_list => tag_list, :parents => parents)
  end

  def self.calculate_costs(perf, h, rates)
    # This expects perf interval to be hourly. That will be the most granular interval available for chargeback.
    unless perf.capture_interval_name == "hourly"
      raise _("expected 'hourly' performance interval but got '%{interval}") % {:interval => perf.capture_interval_name}
    end

    calc_fixed_compute = calc_fixed_compute?(perf)
    h['fixed_compute_metric'] = (h['fixed_compute_metric'] || 0) + 1 if calc_fixed_compute

    rates.each do |rate|
      rate.chargeback_rate_details.each do |r|
        rec    = r.metric && perf.respond_to?(r.metric) ? perf : perf.resource
        metric = r.metric.nil? ? 0 : rec.send(r.metric) || 0
        cost   = r.group == 'fixed' && !calc_fixed_compute ? 0 : r.cost(metric)

        reportable_metric_and_cost_fields(r.rate_name, r.group, metric, cost).each do |k, val|
          next unless attribute_names.include?(k)
          h[k] ||= 0
          h[k] += val
        end
      end
    end
  end

  def self.reportable_metric_and_cost_fields(rate_name, rate_group, metric, cost)
    cost_key         = "#{rate_name}_cost"    # metric cost value (e.g. Storage [Used|Allocated|Fixed] Cost)
    metric_key       = "#{rate_name}_metric"  # metric value (e.g. Storage [Used|Allocated|Fixed])
    cost_group_key   = "#{rate_group}_cost"   # for total of metric's costs (e.g. Storage Total Cost)
    metric_group_key = "#{rate_group}_metric" # for total of metrics (e.g. Storage Total)

    col_hash = {}

    defined_column_for_report = (report_col_options.keys & [metric_key, cost_key]).present?

    if defined_column_for_report
      [metric_key, metric_group_key].each             { |col| col_hash[col] = metric }
      [cost_key,   cost_group_key, 'total_cost'].each { |col| col_hash[col] = cost }
    end

    col_hash
  end

  # check if at least one of these isnt empty\nil\zero
  def self.calc_fixed_compute?(perf)
    fixed_compute_fields = %w(
      derived_vm_numvcpus cpu_usagemhz_rate_average
      cpu_usage_rate_average disk_usage_rate_average
      derived_memory_available derived_memory_used
      net_usage_rate_average derived_vm_used_disk_storage
      derived_vm_allocated_disk_storage
    )
    fixed_compute_fields.any? { |field| perf.send(field).present? && perf.send(field) != 0 }
  end

  def self.get_group_key_ts(perf, interval, tz)
    ts = perf.timestamp.in_time_zone(tz)
    case interval
    when "daily"
      ts = ts.beginning_of_day
    when "weekly"
      ts = ts.beginning_of_week
    when "monthly"
      ts = ts.beginning_of_month
    else
      raise _("interval '%{interval}' is not supported") % {:interval => interval}
    end

    ts
  end

  def self.get_time_range(perf, interval, tz)
    ts = perf.timestamp.in_time_zone(tz)
    case interval
    when "daily"
      [ts.beginning_of_day, ts.end_of_day, ts.strftime("%m/%d/%Y")]
    when "weekly"
      s_ts = ts.beginning_of_week
      e_ts = ts.end_of_week
      [s_ts, e_ts, "Week of #{s_ts.strftime("%m/%d/%Y")}"]
    when "monthly"
      s_ts = ts.beginning_of_month
      e_ts = ts.end_of_month
      [s_ts, e_ts, s_ts.strftime("%b %Y")]
    else
      raise _("interval '%{interval}' is not supported") % {:interval => interval}
    end
  end

  # @option options :start_time [DateTime] used with :end_time to create time range
  # @option options :end_time [DateTime]
  # @option options :interval_size [Fixednum] Used with :end_interval_offset to generate time range
  # @option options :end_interval_offset
  def self.get_report_time_range(options, interval, tz)
    return options[:start_time]..options[:end_time] if options[:start_time]
    raise _("Option 'interval_size' is required") if options[:interval_size].nil?

    end_interval_offset = options[:end_interval_offset] || 0
    start_interval_offset = (end_interval_offset + options[:interval_size] - 1)

    ts = Time.now.in_time_zone(tz)
    case interval
    when "daily"
      start_time = (ts - start_interval_offset.days).beginning_of_day.utc
      end_time   = (ts - end_interval_offset.days).end_of_day.utc
    when "weekly"
      start_time = (ts - start_interval_offset.weeks).beginning_of_week.utc
      end_time   = (ts - end_interval_offset.weeks).end_of_week.utc
    when "monthly"
      start_time = (ts - start_interval_offset.months).beginning_of_month.utc
      end_time   = (ts - end_interval_offset.months).end_of_month.utc
    else
      raise _("interval '%{interval}' is not supported") % {:interval => interval}
    end

    start_time..end_time
  end

  def self.report_cb_model(model)
    model.gsub(/^Chargeback/, "")
  end

  def self.db_is_chargeback?(db)
    db && db.present? && db.safe_constantize < Chargeback
  end

  def self.report_tag_field
    "tag_name"
  end
end # class Chargeback
