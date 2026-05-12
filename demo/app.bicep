extension radius
extension containers
extension gateways
extension routes

param environment string

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'nginx-radius-demo'
  properties: {
    environment: environment
  }
}

resource gateway 'Radius.Compute/gateways@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    gatewayClassName: 'nginx'
    listeners: [
      {
        name: 'http'
        protocol: 'HTTP'
        port: 80
        allowedRoutesFrom: 'All'
      }
    ]
  }
}

resource web 'Radius.Compute/containers@2025-08-01-preview' = {
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

resource route 'Radius.Compute/routes@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    kind: 'HTTP'
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
          containerPort: web.properties.containers.web.ports.http.containerPort
        }
      }
    ]
  }
  dependsOn: [
    gateway
  ]
}
