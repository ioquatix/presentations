
set datafile separator ","

# set terminal svg size 1000, 600 enhanced
set terminal qt size 1920, 1080

set xlabel "Gems"
set xrange [0:*]

set ylabel "Downloads"

set boxwidth 0.9 relative

set style data histograms
set style fill solid 1.0 border -1

plot 'downloads.csv'
