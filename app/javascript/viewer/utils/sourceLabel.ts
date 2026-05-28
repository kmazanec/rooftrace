// GeometrySource enum -> the honest-uncertainty methodology label shown next to
// every measurement number ("from LiDAR" / "from satellite imagery" / ...).
// Mirrors the GeometrySource $def in shared/pipeline_schema.json
// (lidar|imagery|fusion|capture|manual).
export function sourceLabel(source: string | null | undefined): string {
  switch (source) {
    case "lidar":
      return "from LiDAR";
    case "imagery":
      return "from satellite imagery";
    case "fusion":
      return "from LiDAR + imagery";
    case "capture":
      return "from on-site capture";
    case "manual":
      return "manually entered";
    default:
      return "source unknown";
  }
}
