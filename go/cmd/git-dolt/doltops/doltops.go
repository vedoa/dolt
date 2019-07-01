// Package doltops contains functions for performing dolt operations
// using the CLI.
package doltops

import (
	"bufio"
	"fmt"
	"os/exec"
	"strings"

	"github.com/liquidata-inc/ld/dolt/go/cmd/git-dolt/utils"
)

// Clone clones the specified dolt remote, streaming the output from dolt clone to stdout.
func Clone(remote string) error {
	cmd := exec.Command("dolt", "clone", remote)
	if err := runAndStreamOutput(cmd, "dolt clone"); err != nil {
		return err
	}
	return nil
}

// CloneToRevision clones the specified dolt remote and checks it out to the specified revision.
// It streams the output from dolt clone and dolt checkout to stdout.
func CloneToRevision(remote string, revision string) error {
	if err := Clone(remote); err != nil {
		return err
	}

	dirname := utils.LastSegment(remote)
	checkoutCmd := exec.Command("dolt", "checkout", "-b", "git-dolt-pinned", revision)
	checkoutCmd.Dir = dirname
	if err := runAndStreamOutput(checkoutCmd, "dolt checkout"); err != nil {
		return err
	}

	return nil
}

func runAndStreamOutput(cmd *exec.Cmd, name string) error {
	cmdReader, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("error creating StdoutPipe for %s: %v", name, err)
	}

	scanner := bufio.NewScanner(cmdReader)
	go func() {
		for scanner.Scan() {
			text := scanner.Text()
			// TODO: Remove this hacky conditional
			if !strings.HasPrefix(text, "Switched to branch") {
				fmt.Println(scanner.Text())
			}
		}
	}()

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("error starting %s: %v", name, err)
	}

	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("error waiting for %s: %v", name, err)
	}

	return nil
}

// CloneToRevisionSilent clones the specified dolt remote and checks it out to the specified revision,
// suppressing all output from dolt clone and dolt checkout.
func CloneToRevisionSilent(remote string, revision string) error {
	if err := exec.Command("dolt", "clone", remote).Run(); err != nil {
		return fmt.Errorf("error cloning remote repository at %s: %v", remote, err)
	}

	dirname := utils.LastSegment(remote)
	checkoutCmd := exec.Command("dolt", "checkout", "-b", "git-dolt-pinned", revision)
	checkoutCmd.Dir = dirname
	if err := checkoutCmd.Run(); err != nil {
		return fmt.Errorf("error checking out revision %s in directory %s: %v", revision, dirname, err)
	}

	return nil
}
