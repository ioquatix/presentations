
require 'sequel'
require 'fileutils'

require 'async'

require 'async/http/internet'
require 'async/semaphore'
require 'async/barrier'

require 'async/io/notification'

require 'periodical/filter'
require 'csv'

def initialize(context)
	super
	
	@database = Sequel.connect("postgres://localhost/rubygems")
	
	@cache_root = File.expand_path("cache", __dir__)
	@pattern = File.expand_path("*/*", @cache_root)
	@limit = 10_000
	
	@gems = @database.from(:gem_downloads).select_group(:name, :rubygem_id).select_more{sum(:count).as(:total)}.join(:rubygems, id: :rubygem_id).reverse_order(:total).limit(@limit)
end

def count
	installed_gems = Dir.glob(@pattern).map{|path| File.basename(path).rpartition('-').values_at(0, 2)}.to_h
	
	puts "#{installed_gems.size} installed gems."
	
	viable = 0
	
	Dir.glob(@pattern) do |path|
		lib_path = File.expand_path("lib", path)
		unless File.directory?(lib_path)
			puts "#{path} does not have `lib` directory!"
		end
		
		viable += 1
	end
	
	puts "Found #{viable} viable lib paths..."
end

def downloads
	top_downloads = @database.from(:gem_downloads).sum(:count)
	top_total = @gems.sum(:total)
	total = @database.from(:rubygems).count
	
	puts "There are #{total} gems in the database."
	
	puts "Top #{@limit} gems represents #{(@limit.to_f / total * 100.0).to_f.round(2)}% of all gems."
	puts "Top #{@limit} gems accounts for #{(top_total / top_downloads * 100.0).to_f.round(2)}% of all downloads."
	
	width = 10
	
	File.open("downloads.csv", "w") do |file|
		totals = @gems.map{|gem| gem[:total]}
		
		bins = totals.each_slice(width).map{|slice| slice.sum.to_i}
		
		bins.each{|value| file.puts value}
	end
	
	system("gnuplot downloads.gnuplot > downloads.svg")
end

def released
	versions = @database.from(:versions)
	filter = Periodical::Filter::Monthly.new(0)
	
	measure = Console.logger.measure("Versions", versions.count)
	
	histogram = Hash.new{0}
	
	versions.each do |version|
		histogram[filter.key(version[:created_at])] += 1
		measure.increment
	end
	
	csv = CSV.new($stdout)
	csv << ['date', 'count']
	histogram.sort.each do |row|
		csv << row
	end
end

ENSURE = /(.*ensure(.*\n){0,4}.*\$!.*)/
EX = /\$\!/

def analyze
	suspects = []
	count = 0
	
	installed_gems = Dir.glob(@pattern).map{|path| [File.basename(path).rpartition('-').first, path]}.to_h
	
	@gems.limit(10000).each do |gem|
		matches = []
		
		root = installed_gems[gem[:name]]
		source_files = File.expand_path("lib/**/*.rb", root)
		
		Dir.glob(source_files) do |path|
			matched = false
			begin
				code = File.read(path)
				
				code.scan(ENSURE) do |match|
					matches << [path, match]
					matched = true
					count += 1
				end
			rescue ArgumentError
				# Ignore.
			rescue => error
				Async.logger.error(path, error)
			end
		end
		
		unless matches.empty?
			puts "Gem: #{gem[:name]} has #{gem[:total].to_i} downloads."
			root = installed_gems[gem[:name]]
			
			matches.each do |(path, match)|
				puts path.gsub(root, '')
				puts nil, "#{match[0]}", nil
			end
			
			suspects << gem[:name]
		end
	end
	
	puts "Found #{suspects.size} gems with potential issues."
	puts "Found #{count} instances of the pattern."
	puts suspects.inspect
end

def fetch
	installed_gems = Dir.glob(@pattern).map{|path| [File.basename(path).rpartition('-').first, path]}.to_h
	
	puts "#{installed_gems.size} installed gems."
	
	puts "Considering #{@gems.count} gems..."
	
	progress = Console.logger.progress(@gems.count)
	
	skipped = 0
	
	Async do
		semaphore = Async::Semaphore.new(10)
		barrier = Async::Barrier.new(parent: semaphore)
		
		@gems.each do |gem|
			if path = installed_gems[gem[:name]]
				skipped += 1
				
				lib_path = File.join(path, "lib")
				
				unless File.directory?(lib_path)
					puts "#{gem[:name]} doesn't have lib path... (#{gem})"
				end
				
				next
			end
			
			cache_path = File.expand_path(gem[:name][0...3], @cache_root)
			FileUtils.mkdir_p cache_path
			
			Async.logger.info "Fetching #{gem[:name]} which has #{gem[:total].to_i} downloads..."
			
			defer(parent: barrier) do
				system("gem", "unpack", gem[:name], chdir: cache_path)
			end
		end
		
		barrier.wait
	end
	
	puts "Skipped #{skipped} gems."
end

def check
	installed_gems = Dir.glob(@pattern).map{|path| [File.basename(path).rpartition('-').first, path]}.to_h
	
	puts "Found #{installed_gems.size} gem directories"
	
	count = {
		gems: 0,
		files: 0
	}
	
	sums = {}
	
	@gems.each do |gem|
		# puts "Considering #{gem[:name]} #{gem[:total].to_i} downloads..."
		root = installed_gems[gem[:name]]
		
		count[:gems] += 1
		sum = Hash.new{|h,k| h[k] = 0}
		
		source_files = File.expand_path("**/*.rb", root)
		
		Dir.glob(source_files) do |path|
			next unless File.readable?(path)
			
			begin
				code = File.read(path)
				found = Hash.new{|h,k| h[k] = 0}
				
				code.scan(/read_nonblock.*/) do |match|
					sum[match.to_s] += 1
					found[match.to_s] += 1
				end
				
				puts "\t#{path} #{found}" unless found.empty?
				count[:files] += 1
			rescue
				Async.logger.error(path, $!)
			end
		end
		
		unless sum.empty?
			puts "\t ** #{root} #{sum}"
			sums[root] = sum
		end
	end
	
	puts "Out of #{count[:gems]}, #{(sums.size.to_f / count[:gems] * 100.0).to_f.round(2)}% matched."
end

private

def defer(*args, parent: Async::Task.current, &block)
	parent.async do
		notification = Async::IO::Notification.new
		
		thread = Thread.new(*args) do
			yield
		ensure
			notification.signal
		end
		
		notification.wait
		thread.join
	ensure
		notification.close
	end
end
