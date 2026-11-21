package org.acme;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.util.Map;

@Path("/health")
public class HealthResource {
  static final String APP = "${{ values.appName }}";

  @GET
  @Produces(MediaType.APPLICATION_JSON)
  public Map<String, String> health() {
    return HealthPayload.ok(APP);
  }
}
