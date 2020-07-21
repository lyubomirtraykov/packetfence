package main

import (
	"fmt"
	"github.com/robfig/cron/v3"
	"os"
	"sync"
	//	"github.com/coreos/go-systemd/daemon"
	"context"
	"github.com/inverse-inc/packetfence/go/log"
	"github.com/inverse-inc/packetfence/go/maint"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
)

func wrapJob(logger log.PfLogger, j maint.JobSetupConfig) cron.Job {
	var ch = make(chan struct{}, 1)
	ch <- struct{}{}
	return cron.FuncJob(func() {
		select {
		case v := <-ch:
			j.Run()
			ch <- v
		default:
			logger.Info(j.Name() + " Skipped")
		}
	})
}

func mergeArgs(config, args map[string]interface{}) map[string]interface{} {
	newArgs := make(map[string]interface{})
	for k, v := range config {
		newArgs[k] = v
	}

	for k, v := range args {
		newArgs[k] = v
	}

	return newArgs
}

func runJobNow(name string, additionalArgs map[string]interface{}) int {
	jobsConfig := maint.GetMaintenanceConfig()
	if config, found := jobsConfig[name]; found {
		job := maint.GetJob(name, mergeArgs(config.(map[string]interface{}), additionalArgs))
		if job != nil {
			job.Run()
			return 0
		}

		fmt.Printf("Error creating job '%s'\n", name)
	} else {
		fmt.Printf("'%s' is not a valid job task\n", name)
	}

	return 1
}

func makeArgs(args []string) (map[string]interface{}, error) {
	config := make(map[string]interface{})
	for _, arg := range args {
		pair := strings.SplitN(arg, "=", 2)
		if len(pair) != 2 {
			return nil, fmt.Errorf("'%s' is incorrectly formatted\n", arg)
		}

		config[pair[0]] = pair[1]
	}

	return config, nil
}

func main() {
	log.SetProcessName("pfmaint")
	if len(os.Args) > 1 {
		jobName := os.Args[1]
		if additionalArgs, err := makeArgs(os.Args[2:]); err != nil {
			fmt.Printf("%s\n", err.Error())
			os.Exit(1)
		} else {
			os.Exit(runJobNow(jobName, additionalArgs))
		}
	}

	ctx := context.Background()
	logger := log.LoggerWContext(ctx)
	c := cron.New(cron.WithSeconds())
	for _, job := range maint.GetConfiguredJobs(maint.GetMaintenanceConfig()) {
		id := c.Schedule(job.Schedule(), wrapJob(logger, job))
		logger.Info("Job id " + strconv.FormatInt(int64(id), 10))
	}

	w := sync.WaitGroup{}
	w.Add(1)
	c.Start()
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-ch
		w.Done()
	}()

	w.Wait()
	doneCtx := c.Stop()
	<-doneCtx.Done()
}
