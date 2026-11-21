package org.acme;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.Map;
import org.junit.jupiter.api.Test;

class HealthPayloadTest {
  @Test
  void okReturnsStatusAndApp() {
    Map<String, String> body = HealthPayload.ok("demo-quarkus");
    assertEquals("ok", body.get("status"));
    assertEquals("demo-quarkus", body.get("app"));
  }
}
