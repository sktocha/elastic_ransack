module ElasticRansack
  class Search
    include ::ElasticRansack::Naming
    include Enumerable

    attr_reader :options, :search_options, :model, :search_results, :sorts, :globalize

    delegate :results, :each, :each_with_index, :each_with_hit, :empty?, :size, :[], to: :search_results
    delegate :total_entries, :per_page, :total_pages, :current_page, :previous_page, :next_page,
      :offset, :out_of_bounds?, :records, to: :search_results

    alias_method :klass, :model

    DATETIME_REGEXP = /\d{2}\.\d{2}.\d{4} \d{2}\:\d{2}/
    DATE_REGEXP = /\d{2}\.\d{2}.\d{4}/

    def initialize(model, options, search_options)
      search_options ||= {}
      search_options.reverse_merge!(globalize: true)
      @model = model
      @options = options.stringify_keys
      @search_options = search_options || {}
      @sorts = []
      @globalize = @search_options.delete(:globalize)
      sorting = @options.delete('s')
      if sorting.blank?
        add_sort('_score', 'desc')
        add_sort('id', 'desc')
      else
        sorting_split = sorting.split(/\s+/, 2)
        add_sort(sorting_split[0], sorting_split[1] || 'asc')
      end
    end

    def add_sort(name, dir)
      @sorts << OpenStruct.new(name: name, dir: dir)
    end

    def search
      @search_results ||= begin
        query_string = []
        filters = []

        options.except('m').each do |k, v|
          next if v.blank?
          v = ElasticRansack.normalize_integer_vals(k, v)

          if k == 'q_cont' || k == 'q_eq'
            query_string << "#{v}" if v.present?
            next
          end

          if k =~ /^(.+)_cont$/
            attr = $1
            attr = "#{$1.sub(/^translations_/, '')}_#{I18n.locale}" if globalize && attr =~ /^translations_(.+)/
            attr_query = [
                v.split.map { |part| "#{attr}:*#{part.lucene_escape}*" }.join(' AND '),
                v.split.map { |part| "#{attr}:\"#{part.lucene_escape}\"" }.join(' AND ')
            ]
            query_string << attr_query.map { |q| "(#{q})" }.join(' OR ')
            next
          else

            if k == 'g'
              filters << {bool: {minimum_should_match: 1, should: []}}
              v.each do |group|
                filters.first[:bool][:should] << {bool: {filter: group.map { |kk, vv| build_filters(kk.to_s, vv) }}}
              end
            else
              filters << build_filters(k, v)
              filters.flatten!
            end

          end

        end

        sort = sorts.map { |s| {s.name => s.dir} }

        query = {bool: {}}
        if query_string.present?
          query[:bool][:must] = {query_string: {query: query_string.map{|part| "(#{part})"}.join(' OR ')}}
        end
        query[:bool][:filter] = filters if filters.present?
        query.delete(:bool) if query[:bool].blank?

        per_page = @search_options[:per_page] || 50
        page = @search_options[:page].presence || 1

        es_options = {query: query, sort: sort}
        es_options.delete(:query) if query.blank?
        es_options.merge!(_source: @search_options[:fields]) if @search_options[:fields].present?

        __elasticsearch__.search(es_options).paginate(per_page: per_page, page: page)
      end
    end

    def build_filters(k, v)
      filters = []
      key_data = parse_key(k)
      if key_data.present?
        v = format_value(v, detect_field_type(key_data[:fields].first))
        if key_data[:fields].size > 1
          filters << {bool: {minimum_should_match: 1, should: []}}
          key_data[:fields].each do |field|
            filters.last[:bool][:should] << key_data[:predicate].query.call(field, v)
          end
        else
          filters << key_data[:predicate].query.call(key_data[:fields].first, v)
        end
      end
      filters
    end

    def parse_key(k)
      raw_key = k.match(ElasticRansack.predicates.map(&:regexp).join('|')).captures.compact.first.to_s
      predicate = ElasticRansack.predicates.find{ |p| k.sub(raw_key, '')[1..-1] == p.name }
      return {} unless predicate || raw_key.present?
      {predicate: predicate, fields: raw_key.split('_or_')}
    end

    def translate(*args)
      model.human_attribute_name(args.first)
    end

    def format_value(v, type = nil)
      if type == :boolean
        if v == 1 || v == '1'
          true
        elsif v == 0 || v == '0'
          false
        else
          v
        end
      elsif v =~ DATETIME_REGEXP
        ElasticRansack.datetime_parser.call(v)
      elsif v =~ DATE_REGEXP
        ElasticRansack.datetime_parser.call(v).to_date
      else
        v
      end
    end

    def detect_field_type(field)
      [field.to_sym, field.to_s].each do |formatted_field|
        r = field_mapping(formatted_field)
        type = r.try(:[], :type) || r.try(:type)
        return type if type
      end
      :boolean if field.start_with?('is_')
    end

    def field_mapping(field)
      try(:model).try(:mapping).try(:instance_variable_get, :@mapping).try(:[], field) ||
        try(:model).try(:columns_hash).try(:[], field)
    end

    def method_missing(*args, &block)
      @model.send(*args, &block)
    end
  end
end
