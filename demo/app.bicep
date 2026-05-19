extension radius
extension containers
extension gateways
extension routes

param environment string
param gatewayClassName string = 'nginx'

resource app 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'nginx-radius-demo'
  properties: {
    environment: environment
  }
}

resource gateway 'gateways:Radius.Compute/gateways@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    gatewayClassName: gatewayClassName
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

resource web 'containers:Radius.Compute/containers@2025-08-01-preview' = {
  name: 'web'
  properties: {
    environment: environment
    application: app.id
    connections: {}
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

resource route 'routes:Radius.Compute/routes@2025-08-01-preview' = {
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
