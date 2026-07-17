package main

import (
	"log"
	"os"

	"github.com/Samyazz/zerops-k8s/internal/edge"
	"github.com/Samyazz/zerops-k8s/internal/nodeagent"
)

func main() {
	switch os.Getenv("K8S_MODE") {
	case "node":
		if err := nodeagent.Run(); err != nil {
			log.Fatal(err)
		}
	case "edge":
		if err := edge.Run(); err != nil {
			log.Fatal(err)
		}
	default:
		log.Fatal("K8S_MODE must be node or edge")
	}
}
