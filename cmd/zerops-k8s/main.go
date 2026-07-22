package main

import (
	"log"

	"github.com/Samyazz/zerops-k8s/internal/nodeagent"
)

func main() {
	if err := nodeagent.Run(); err != nil {
		log.Fatal(err)
	}
}
