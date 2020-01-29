setwd("~/Documents/case_to_infection/")

library(ggplot2)
library(tidyverse)
library(lubridate)
library(cowplot)
library(patchwork)
library(ggpmisc)
library(ggpubr)
library(maptools)
library(maps)
library(data.table)

weibull_stan_draws <- read.csv("data/backer_weibull_draws.csv")

source("code/analysis_functions.R")
source("code/plot_china_map.R")

## load the data - try to only do this once otherwise auth token gets stale
source("code/pull_data.R")
## Comment out next line, as is used for automatic user input from above script
1
## If you don't have a google account, you can run this instead
## source("code/load_data_manual.R")

## These column names will be kept as keys for the rest of the analysis
key_colnames <- c("ID","age","country", "sex","city","province",
                  "latitude","longitude")
## These are the column names with used variables
var_colnames <- c("date_confirmation","date_onset_symptoms","date_admission_hospital")
use_colnames <- c(key_colnames, var_colnames)

## Number of bootstrap samples to take. Set this to something small for a quick run
repeats <- 100

## First step is to clean and take a look at the data
## This combines the data for Hubei and other locations in China
## Note this is ONLY China
source("code/data_clean_all.R")
china_dat <- combined_dat[combined_dat$country == "China",]

####################################
## CONFIRMATION DELAY DISTRIBUTION
####################################
## Any instant confirmations?
china_dat %>% filter(confirmation_delay < 1)
## Assume that there is at least a 1 day delay to reporting, so < 1 day is set to 1
china_dat <- china_dat %>% mutate(confirmation_delay = ifelse(confirmation_delay < 1, 1, confirmation_delay))
use_delays <- china_dat %>% select(confirmation_delay) %>% drop_na() %>% pull(confirmation_delay)
## Fit a geometric distribution to the confirmation delay distribution
fit1 <- optim(c(0.1), fit_geometric, dat=use_delays-1,method="Brent",lower=0,upper=1)
fit_line1 <- dgeom(seq(0,25,by=1),prob=fit1$par)
fit_line_dat1 <- data.frame(x=seq(1,26,by=1),y=fit_line1)

p_other_confirm_fit<- ggplot(china_dat) + 
  geom_histogram(aes(x=confirmation_delay,y=..density..),binwidth=1,col="black") +
  geom_line(data=fit_line_dat1, aes(x=x,y=y), col="red",size=1) +
  scale_x_continuous(breaks=seq(0,30,by=5),labels=seq(0,30,by=5)) +
  scale_y_continuous(expand=c(0,0),limits=c(0,0.2)) +
  geom_vline(xintercept=1,linetype="dashed") +
  ylab("Probability density") + xlab("Days since symptom onset") +
  ggtitle("Distribution of delays between symptom\n onset and confirmation") +
  theme_pubr()
p_other_confirm_fit

####################################
## HOSPITALISATION DELAY DISTRIBUTION
####################################
## Assume that there is at least a 1 day delay to reporting, so < 1 day is set to 1
use_delays <- china_dat %>% select(hospitalisation_delay) %>% drop_na() %>% pull(hospitalisation_delay)
## Fit a geometric distribution to hospitalisation delay distribution
fit2 <- optim(c(0.1), fit_geometric, dat=use_delays,method="Brent",lower=0,upper=1)
times <- seq(0,25,by=1)
fit_line2 <- dgeom(times,prob=fit2$par)
fit_line_dat2 <- data.frame(x=times,y=fit_line2)

p_other_hosp_fit<- ggplot(china_dat) + 
  geom_histogram(aes(x=hospitalisation_delay,y=..density..),binwidth=1) +
  geom_line(data=fit_line_dat2, aes(x=x,y=y), col="red") +
  scale_x_continuous(breaks=seq(0,25,by=1)) +
  ggtitle("Distribution of delays between symptom\n onset and hospitalisation (not great fit)") +
  theme_pubr()
p_other_hosp_fit
## Fit isn't great for first day


####################################
## SYMPTOM ONSET DISTRIBUTION
## UPDATED -- Now using the distribution from Weibull derived by
## Backer et al.
####################################
## 1000 draws from their posterior
n_samps <- 1000
times <- seq(0,25,by=0.1)
weibull_dists <- matrix(0, nrow=1000, ncol=length(times))
for(i in seq_len(n_samps)){
  pars <- weibull_stan_draws[i,]
  alpha <- pars$alpha
  sigma <- pars$sigma
  weibull_dists[i,] <- dweibull(times, alpha, sigma)
}
colnames(weibull_dists) <- times
weibull_dists_bounds <- as.data.frame(t(apply(weibull_dists, 2, function(x) quantile(x, c(0.025,0.5,0.975)))))
colnames(weibull_dists_bounds) <- c("lower","median","upper")
weibull_dists_bounds$times <- times

p_incubation <- ggplot(weibull_dists_bounds) + 
  geom_ribbon(aes(x=times, ymax=upper,ymin=lower),fill="grey70",alpha=0.4,col="black") + 
  geom_line(aes(x=times,y=median),size=1) +
  ylab("Probability density") +
  xlab("Days since onset of infection") +
  ggtitle("Incubation period distribution\n (Weibull, time from infection to symptoms)") +
  scale_y_continuous(limits=c(0,0.3),expand=c(0,0),breaks=seq(0,0.3,by=0.05)) +
  scale_x_continuous(expand=c(0,0)) +
  theme_pubr()
p_incubation


#############################
## FULL AUGMENTATION
#############################
china_dat <- combined_dat[combined_dat$country == "China",]

## Now let's repeat this process many times to get a distribution
sim_data_infections <- matrix(NA, nrow=repeats, ncol=nrow(china_dat))
sim_data_symptoms <- matrix(NA, nrow=repeats, ncol=nrow(china_dat))

## For each sample, draw a Weibull distribution from the posterior for 
## the incubation period and generate augmented infection times for all individuals
for(i in seq_len(repeats)){
  ## Random draw from the weibull posterior
  incu_period_rand <- weibull_stan_draws[sample(seq_len(nrow(weibull_stan_draws)),1),]
  alpha <- incu_period_rand$alpha
  sigma <- incu_period_rand$sigma
  
  ## Get symptom onset and infection times
  tmp <- augment_infection_times(china_dat, 
                                 inc_period_alpha=alpha, 
                                 inc_period_sigma=sigma, 
                                 p_confirm_delay=fit1$par)
  
  sim_data_infections[i,] <- tmp$augmented_infection_times
  sim_data_symptoms[i,] <- tmp$augmented_symptom_onsets
}

sim_data_infections_melted <- reshape2::melt(sim_data_infections)
sim_data_symptoms_melted <- reshape2::melt(sim_data_symptoms)

sim_data_infections_melted$var <- "date_infection"
sim_data_symptoms_melted$var <- "date_onset_symptoms"

colnames(sim_data_infections_melted) <- colnames(sim_data_symptoms_melted) <- c("repeat_no","individual","date","var")

## Combine symptom onsets and infections and conert to dates
sim_data_all <- rbind(sim_data_infections_melted, sim_data_symptoms_melted)
sim_data_all$date <- as.Date(floor(sim_data_all$date), origin="1970-01-01")

## Sum by repeat, variable and date ie. events per day
sim_data_sum <- sim_data_all %>% group_by(repeat_no, var, date) %>% tally()
sim_data_sum <- sim_data_sum %>% ungroup() %>% complete(repeat_no, var, date, fill=list(n=0))

variable_key2 <- c("date_confirmation"="Confirmation date (known)",
                   "date_onset_symptoms"="Onset of symptoms for cases observed to date",
                   "date_admission_hospital"="Hospital admission date",
                   "date_infection"="Augmented infection date for cases observed to date")


################################################
## OVERALL PLOT
## Distribution of times for each date
sim_data_quantiles <- sim_data_sum %>% group_by(date, var) %>% 
  do(data.frame(t(quantile(.$n, probs = c(0.025,0.5,0.975),na.rm=TRUE))))

## Get confirmation time data
confirm_data <- china_dat %>% filter(!is.na(date_confirmation)) %>% group_by(date_confirmation) %>% tally()
confirm_data$Variable <- "Confirmed cases"

sim_data_quantiles$var <- variable_key2[sim_data_quantiles$var]

colnames(sim_data_quantiles) <- c("date","Variable","lower","median","upper")
augmented_data_plot <- plot_augmented_data(sim_data_quantiles, confirm_data,ymax=500,ybreaks=50)
augmented_data_plot

## Distribution of times for each individual

sim_data_quantiles_indiv <- sim_data_all %>% group_by(individual, var) %>% 
  do(data.frame(t(quantile(as.numeric(.$date), probs = c(0.025,0.5,0.975),na.rm=TRUE))))

sim_data_quantiles_indiv$X2.5. <- as.Date(sim_data_quantiles_indiv$X2.5., origin="1970-01-01")
sim_data_quantiles_indiv$X50. <- as.Date(sim_data_quantiles_indiv$X50., origin="1970-01-01")
sim_data_quantiles_indiv$X97.5. <- as.Date(sim_data_quantiles_indiv$X97.5., origin="1970-01-01")


#########################
## FINAL HOUSEKEEPING
## Tidy up data to share
sim_data_infections1 <- as.data.frame(t(sim_data_infections[1:100,]))
for(i in seq_len(ncol(sim_data_infections1))){
  sim_data_infections1[,i] <- as.Date(floor(sim_data_infections1[,i]), origin="1970-01-01")
}
sim_data_infections1 <- bind_cols(china_dat,sim_data_infections1)


sim_data_symptoms1 <- as.data.frame(t(sim_data_symptoms[1:100,]))
for(i in seq_len(ncol(sim_data_symptoms1))){
  sim_data_symptoms1[,i] <- as.Date(floor(sim_data_symptoms1[,i]), origin="1970-01-01")
}
sim_data_infections1 <- bind_cols(china_dat,sim_data_symptoms1)

write_csv(sim_data_infections1, path="augmented_data/augmented_infection_times.csv")
write_csv(sim_data_symptoms1, path="augmented_data/augmented_symptom_times.csv")


## Create results panel plot programmatically
element_text_size <- 10
text_size_theme <- theme(title=element_text(size=element_text_size), 
                         axis.text=element_text(size=element_text_size), 
                         axis.title = element_text(size=element_text_size))
p_other_confirm_fit1 <- p_other_confirm_fit + text_size_theme
p_incubation1 <- p_incubation + text_size_theme
assumption_plot <- plot_grid(p_other_confirm_fit1, p_incubation1,ncol=2,align="hv")
augmented_data_plot1 <- augmented_data_plot + theme(legend.position=c(0.25,0.25))
layout <- c(
  area(t=0,b=12,l=0,r=18),
  area(t=2,b=7,l=2,r=14)
)

results_panel <- augmented_data_plot1 + assumption_plot + plot_layout(design=layout)

#######################
## SPATIAL PLOTS
#######################
individual_key <- china_dat[,c("ID","age","country","sex","city","province","latitude","longitude")]
colnames(individual_key)[1] <- "individual"
sim_data_all <- as_tibble(sim_data_all)

merged_data <- right_join(individual_key, sim_data_all,by=c("individual"))
merged_data <- merged_data[!is.na(merged_data$date),]
#############################
## Aggregate by province
## Get confirmation time data
confirm_dat_province <- china_dat %>% filter(!is.na(china_dat$date_confirmation)) %>% 
  group_by(province, date_confirmation) %>% tally() %>%
  ungroup() %>% complete(province, date_confirmation, fill=list(n=0))
confirm_dat_province$Variable <- "Confirmed cases"

province_data <- merged_data %>% 
  group_by(repeat_no, var, date, province) %>%
  tally() %>% ungroup() %>%
  complete(repeat_no, var, date, province, fill=list(n=0))


sim_data_quantiles_province <- province_data %>% group_by(date, var, province) %>% 
  do(data.frame(t(quantile(.$n, probs = c(0.025,0.5,0.975),na.rm=TRUE))))

sim_data_quantiles_province$var <- variable_key2[sim_data_quantiles_province$var]
colnames(sim_data_quantiles_province) <- c("date","Variable","province","lower","median","upper")
total_confirmed_prov <- confirm_dat_province %>% group_by(province) %>% summarise(n=sum(n))
total_confirmed_prov <- total_confirmed_prov[order(-total_confirmed_prov$n),]
factor_order <- as.character(total_confirmed_prov$province)

confirm_dat_province$province <- factor(as.character(confirm_dat_province$province), 
                                         levels=factor_order)
sim_data_quantiles_province$province <- factor(as.character(sim_data_quantiles_province$province), 
                                               levels=factor_order)


by_province <- plot_augmented_data_province(sim_data_quantiles_province, confirm_dat_province)
top_6 <- factor_order[1:6]
by_province_top6 <- plot_augmented_data_province(sim_data_quantiles_province[sim_data_quantiles_province$province %in% top_6,], 
                                                 confirm_dat_province[confirm_dat_province$province %in% top_6,])
by_province_top6 <- by_province_top6 + facet_wrap(~province, ncol=3, scales="free_y") + theme(legend.text=element_text(size=10))
by_province_top6

## Plot time from start
p_start_delay_dist <- plot_time_from_start(sim_data_infections_melted, individual_key,xmax=75)
p_start_delay_dist


###########################
## PLOT STUFF ON A MAP
###########################
## Want to work with cumulative infections
dat_cumu <- province_data  %>% group_by(date, var, province) %>% mutate(cumu_n=cumsum(n))
dat_cumu_quantiles <- dat_cumu %>% group_by(date, var, province) %>% 
  do(data.frame(t(quantile(.$cumu_n, probs = c(0.025,0.5,0.975),na.rm=TRUE)))) %>% ungroup()

dat_cumu_mean <- province_data  %>% group_by(date, var, province) %>% 
  mutate(cumu_n=cumsum(n)) %>% summarise(mean_n = mean(cumu_n))

dat_cumu_quantiles$var <- variable_key2[dat_cumu_quantiles$var]
dat_cumu_mean$var <- variable_key2[dat_cumu_mean$var]
colnames(dat_cumu_quantiles) <- c("date","Variable","province","lower","median","upper")
colnames(dat_cumu_mean) <- c("date","Variable","province","mean")

total_confirmed_prov <- confirm_dat_province %>% group_by(province) %>% summarise(n=sum(n))
total_confirmed_prov <- total_confirmed_prov[order(-total_confirmed_prov$n),]
factor_order <- as.character(total_confirmed_prov$province)

confirm_dat_province$province <- factor(as.character(confirm_dat_province$province), 
                                        levels=factor_order)
dat_cumu_quantiles$province <- factor(as.character(dat_cumu_quantiles$province), 
                                               levels=factor_order)
dat_cumu_mean$province <- factor(as.character(dat_cumu_mean$province), 
                                      levels=factor_order)





map_stuff <- get_map_shape()
china_map_dat <- map_stuff$data
label_dt <- map_stuff$labels

## Do the provinces match up?
in_map_prov <- unique(china_map_dat$province_EN)
in_dat_prov <- as.character(unique(sim_data_quantiles_province$province))
setdiff(in_map_prov, in_dat_prov)
## Missing non-mainland territories and two are misnamed
china_map_dat[china_map_dat$province_EN == "Tianjin City", "province_EN"] <- "Tianjin"
china_map_dat[china_map_dat$province_EN == "Guangxi ", "province_EN"] <- "Guangxi"

missing_provinces <- c("Taiwan", "Hong Kong","Tibet")
colnames(china_map_dat)[2] <- "province"
china_map_dat <- as_tibble(china_map_dat)
china_map_dat <- china_map_dat %>%  mutate(province=ifelse(id==177,"Tibet",province))
china_map_dat <- china_map_dat %>% mutate(province=ifelse(id== 538,"Taiwan",province))
china_map_dat <- china_map_dat %>% mutate(province=ifelse(id== 538,"Hong Kong",province))
## Hong Kong and Taiwan missing so will add as points

in_map_prov <- unique(china_map_dat$province)
in_dat_prov <- as.character(unique(dat_cumu_quantiles$province))
setdiff(in_map_prov, in_dat_prov)

china_map_dat$province <- factor(china_map_dat$province, levels=c(levels(dat_cumu_quantiles$province),"Tibet"))

#dat_cumu_quantiles$province <- as.character(dat_cumu_quantiles$province)
#dat_cumu_quantiles <- dat_cumu_quantiles %>% ungroup() %>% mutate(province=ifelse(is.na(province),"Tibet",province))
#dat_cumu_quantiles$province <- factor(dat_cumu_quantiles$province, levels=c(levels(china_map_dat$province)))


dat_cumu_mean$province <- as.character(dat_cumu_mean$province)
dat_cumu_mean <- dat_cumu_mean %>% ungroup() %>% mutate(ifelse(province-=s.na(province),"Tibet",province))
dat_cumu_mean$province <- factor(dat_cumu_mean$province, levels=c(levels(china_map_dat$province)))

#dat_cumu_quantiles_fill <- dat_cumu_quantiles %>% ungroup() %>% 
#  select(date, Variable, province, median) %>%
#  complete(date, Variable, province, fill=list(median=0,lower=0,upper=0))

dat_cumu_mean_fill <- dat_cumu_mean %>% ungroup() %>% 
  select(date, Variable, province, mean) %>%
  complete(date, Variable, province, fill=list(mean=0))

all_map_dat <- full_join(china_map_dat, dat_cumu_mean_fill, by="province")
all_map_dat <- all_map_dat %>% drop_na()

label_dt[label_dt$id == "898","province_EN"] <- "Hong Kong"

dates <- unique(all_map_dat$date)
dates <- dates[28:length(dates)]
for(i in seq_along(dates)){
  print(i)
  p <- ggplot(all_map_dat[all_map_dat$date == dates[i],], aes(x = long, y = lat, group = group,fill=log10(mean))) +
    geom_polygon()+
    geom_path()+
    scale_fill_gradient2(low="blue",high="red",na.value="blue",mid="orange",limits=c(0,5),midpoint=3,#midpoint=120,limits=c(0,170),
                         guide = guide_colourbar(barwidth = 0.8, barheight = 10)) + 
    geom_text(data = label_dt, aes(x=x, y=y, label = province_EN),inherit.aes = F, col="white") +
    ggtitle(paste0("Date: ", dates[i])) +
    theme_classic() + theme(panel.background = element_rect(fill="black"), legend.position=c(0.95,0.3)) + facet_wrap(~Variable,ncol=1)
  #png(paste0("~/tmp/", i,"_infections.png"),height=10,width=15,res=300,units="in")
  png(paste0("plots/",i,"_infections.png"),height=20,width=15,units="in",res=90)
  plot(p)
  dev.off()
}
