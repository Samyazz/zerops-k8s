package nodeagent

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

type commandRunner interface {
	run(context.Context, string, []string, string) (string, error)
}

type osRunner struct{}

func (osRunner) run(ctx context.Context, name string, args []string, stdin string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		return output.String(), fmt.Errorf("%s failed: %w: %s", name, err, strings.TrimSpace(output.String()))
	}
	return output.String(), nil
}
