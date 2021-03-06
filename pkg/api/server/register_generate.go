package server

import (
	"net/http"

	"github.com/containers/podman/v2/pkg/api/handlers/libpod"
	"github.com/gorilla/mux"
)

func (s *APIServer) registerGenerateHandlers(r *mux.Router) error {
	// swagger:operation GET /libpod/generate/{name:.*}/systemd libpod libpodGenerateSystemd
	// ---
	// tags:
	//  - containers
	//  - pods
	// summary: Generate Systemd Units
	// description: Generate Systemd Units based on a pod or container.
	// parameters:
	//  - in: path
	//    name: name:.*
	//    type: string
	//    required: true
	//    description: Name or ID of the container or pod.
	//  - in: query
	//    name: useName
	//    type: boolean
	//    default: false
	//    description: Use container/pod names instead of IDs.
	//  - in: query
	//    name: new
	//    type: boolean
	//    default: false
	//    description: Create a new container instead of starting an existing one.
	//  - in: query
	//    name: time
	//    type: integer
	//    default: 10
	//    description: Stop timeout override.
	//  - in: query
	//    name: restartPolicy
	//    default: on-failure
	//    type: string
	//    enum: ["no", on-success, on-failure, on-abnormal, on-watchdog, on-abort, always]
	//    description: Systemd restart-policy.
	//  - in: query
	//    name: containerPrefix
	//    type: string
	//    default: container
	//    description: Systemd unit name prefix for containers.
	//  - in: query
	//    name: podPrefix
	//    type: string
	//    default: pod
	//    description: Systemd unit name prefix for pods.
	//  - in: query
	//    name: separator
	//    type: string
	//    default: "-"
	//    description: Systemd unit name separator between name/id and prefix.
	// produces:
	// - application/json
	// responses:
	//   200:
	//     description: no error
	//     schema:
	//       type: object
	//       additionalProperties:
	//         type: string
	//   500:
	//     $ref: "#/responses/InternalError"
	r.HandleFunc(VersionedPath("/libpod/generate/{name:.*}/systemd"), s.APIHandler(libpod.GenerateSystemd)).Methods(http.MethodGet)

	// swagger:operation GET /libpod/generate/{name:.*}/kube libpod libpodGenerateKube
	// ---
	// tags:
	//  - containers
	//  - pods
	// summary: Generate a Kubernetes YAML file.
	// description: Generate Kubernetes YAML based on a pod or container.
	// parameters:
	//  - in: path
	//    name: name:.*
	//    type: string
	//    required: true
	//    description: Name or ID of the container or pod.
	//  - in: query
	//    name: service
	//    type: boolean
	//    default: false
	//    description: Generate YAML for a Kubernetes service object.
	// produces:
	// - application/json
	// responses:
	//   200:
	//     description: no error
	//     schema:
	//      type: string
	//      format: binary
	//   500:
	//     $ref: "#/responses/InternalError"
	r.HandleFunc(VersionedPath("/libpod/generate/{name:.*}/kube"), s.APIHandler(libpod.GenerateKube)).Methods(http.MethodGet)
	return nil
}
