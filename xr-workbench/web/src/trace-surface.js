import * as THREE from "three";

// DOM patches cannot paint into WebXR: copy D2's SVG into a texture instead.
// The surface is shared by the standalone trace and the in-session demo.
export function createTraceSurface(world) {
  const material = new THREE.MeshBasicMaterial({
    color: 0xffffff,
    side: THREE.DoubleSide,
  });
  const mesh = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), material);
  mesh.position.set(0, 1.62, -1.8);
  mesh.visible = false;
  world.scene.add(mesh);
  let generation = 0;
  const viewerPosition = new THREE.Vector3();
  const viewerRotation = new THREE.Quaternion();
  const viewerOffset = new THREE.Vector3();
  const stopFollowingViewer = world.onXRFrame((frame) => {
    if (!mesh.visible) return;
    const referenceSpace = world.xrReferenceSpace;
    if (!referenceSpace) return;
    const pose = frame.getViewerPose(referenceSpace);
    if (!pose) return;

    viewerPosition.set(
      pose.transform.position.x,
      pose.transform.position.y,
      pose.transform.position.z,
    );
    viewerRotation.set(
      pose.transform.orientation.x,
      pose.transform.orientation.y,
      pose.transform.orientation.z,
      pose.transform.orientation.w,
    );
    viewerOffset.set(0, 0, -1.5).applyQuaternion(viewerRotation);
    mesh.position.copy(viewerPosition).add(viewerOffset);
    mesh.quaternion.copy(viewerRotation);
  });

  return {
    setVisible(visible) {
      mesh.visible = visible;
    },
    async show(blob) {
      const current = ++generation;
      const url = URL.createObjectURL(blob);
      let image;
      let texture;
      try {
        image = await new THREE.TextureLoader().loadAsync(url);
        const canvas = document.createElement("canvas");
        canvas.width = image.image.naturalWidth || image.image.width;
        canvas.height = image.image.naturalHeight || image.image.height;
        const context = canvas.getContext("2d");
        if (!context) throw new Error("Could not rasterize the trace diagram");
        context.drawImage(image.image, 0, 0, canvas.width, canvas.height);
        texture = new THREE.CanvasTexture(canvas);
      } finally {
        image?.dispose();
        URL.revokeObjectURL(url);
      }
      if (current !== generation) {
        texture.dispose();
        return false;
      }
      texture.colorSpace = THREE.SRGBColorSpace;
      material.map?.dispose();
      material.map = texture;
      material.needsUpdate = true;
      const ratio = texture.image.width / texture.image.height;
      mesh.scale.set(
        Math.min(1.8, 0.92 * ratio),
        Math.min(0.92, 1.8 / ratio),
        1,
      );
      return true;
    },
    dispose() {
      ++generation;
      stopFollowingViewer();
      mesh.removeFromParent();
      material.map?.dispose();
      mesh.geometry.dispose();
      material.dispose();
    },
  };
}
