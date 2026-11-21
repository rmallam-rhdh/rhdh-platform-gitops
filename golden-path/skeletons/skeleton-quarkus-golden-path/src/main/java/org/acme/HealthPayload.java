package org.acme;

import java.util.LinkedHashMap;
import java.util.Map;

/** JSON body for GET /health — kept free of Quarkus so javac can unit-test it. */
public final class HealthPayload {
  private HealthPayload() {}

  public static Map<String, String> ok(String app) {
    Map<String, String> body = new LinkedHashMap<>();
    body.put("status", "ok");
    body.put("app", app);
    return body;
  }
}
