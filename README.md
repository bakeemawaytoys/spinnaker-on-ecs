Overview
===

Deploys Spinnaker to AWS ECS Fargate with AWS App Mesh integration.  It is an attempt to create an alternative to deploying Spinnaker to K8s using Halyard.  While Halyard simplifies deploying Spinnaker to some degree, it has some drawbacks.  The first drawback is that it only provides K8s as a deployment target.  While K8s is very powerful and has some great features, it is also very complex and overkill if Spinnaker is the only thing that will be deployed on the cluster.  The second drawback is that Halyard generates its the Spinnaker configuration files in response to CLI commands from the user.  This interactive approach does not lend itself to a GitOps workflow.  The third drawback is that Halyard is itself a web service that must be run somewhere and it maintains state on its filesystem.  The conveniences provided by Halyard does not seem to justify the operational overhead of running it unless it is used to manage a large number of Spinnaker clusters. 

In K8s, the config map feature allows for custom configuration files to be deployed without the need to create custom Docker images for the Spinnaker services. ECS does not provide any analog to config maps.  Alternatives to config maps are 1) modifying the default Spinnaker images by installing custom configuration files, 2) running a side car container with each Spinnaker service that installs a custom configuration on a shared volume prior to the start of the service container, or 3) specifying service configuration options as environment variables and/or command line options in the container definition.  The Spinnaker services are written in Java using the Spring framework.  The services are configured using Spring properties with the default properties specified in a Yaml file packaged in the Docker image.  Spring provides [a number of ways to specify property values](https://www.baeldung.com/properties-with-spring) so, for simpler Spinnaker setups, the default Spinnaker images can be used on ECS with customized configuration provided through environment variables.  For this demonstration project, the third option is used to customize configuration.

```yaml
server:
  port: 8084
  compression:
    enabled: true


redis:
  connection: redis://localhost:6379

services:
  deck:
    baseUrl: http://localhost:9000
```

References
===
* https://www.spinnaker.io/reference/architecture/
* https://www.baeldung.com/properties-with-spring
* https://www.baeldung.com/configuration-properties-in-spring-boot
* https://storage.googleapis.com/halconfig
* https://github.com/spinnaker/kleat/blob/master/docs/docs.md