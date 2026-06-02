extension radius
extension radiusCompute

param environment string
param routeHostname string = 'web.example.com'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'default-radius-demo'
  properties: {
    environment: environment
  }
}

resource web 'radiusCompute:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    containers: {
      web: {
        image: 'nginx:alpine'
        ports: {
          http: {
            containerPort: 80
            protocol: 'TCP'
          }
        }
      }
    }
  }
}

resource route 'radiusCompute:Radius.Compute/routes@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    kind: 'HTTP'
    hostnames: [
      routeHostname
    ]
    rules: [
      {
        matches: [
          {
            httpPath: '/'
          }
        ]
        destinationContainer: {
          resourceId: web.id
          containerName: 'web'
          containerPortName: 'http'
        }
      }
    ]
  }
}
