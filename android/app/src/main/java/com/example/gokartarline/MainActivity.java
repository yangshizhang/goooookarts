package com.example.gokartarline;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PointF;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.os.Bundle;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.graphics.SurfaceTexture;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class MainActivity extends Activity {
    private static final int REQUEST_PERMISSIONS = 7;
    private TextureView cameraPreview;
    private DrivingLineOverlay overlay;
    private TextView status;
    private CameraDevice cameraDevice;
    private CameraCaptureSession cameraSession;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        loadSampleTrack();
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA, Manifest.permission.ACCESS_FINE_LOCATION}, REQUEST_PERMISSIONS);
        } else {
            startCameraWhenReady();
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_PERMISSIONS && grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            startCameraWhenReady();
        } else {
            status.setText("未授权相机：仅显示行车线预览");
        }
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        cameraPreview = new TextureView(this);
        overlay = new DrivingLineOverlay(this);
        root.addView(cameraPreview, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        root.addView(overlay, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout hud = new LinearLayout(this);
        hud.setOrientation(LinearLayout.VERTICAL);
        hud.setPadding(24, 18, 24, 18);
        hud.setBackgroundColor(0x66000000);
        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setTextSize(18);
        status.setText("GoKartARLine Android · 示例赛道");
        hud.addView(status);

        LinearLayout controls = new LinearLayout(this);
        controls.setGravity(Gravity.CENTER);
        controls.setPadding(16, 16, 16, 16);
        controls.setBackgroundColor(0x55000000);
        Button farther = new Button(this);
        farther.setText("路线更远");
        farther.setOnClickListener(v -> overlay.setRenderDistance(overlay.getRenderDistance() + 30));
        Button nearer = new Button(this);
        nearer.setText("路线更近");
        nearer.setOnClickListener(v -> overlay.setRenderDistance(Math.max(30, overlay.getRenderDistance() - 30)));
        Button higher = new Button(this);
        higher.setText("高度+");
        higher.setOnClickListener(v -> overlay.setVerticalOffset(overlay.getVerticalOffset() + 8));
        Button lower = new Button(this);
        lower.setText("高度-");
        lower.setOnClickListener(v -> overlay.setVerticalOffset(overlay.getVerticalOffset() - 8));
        controls.addView(farther);
        controls.addView(nearer);
        controls.addView(higher);
        controls.addView(lower);

        FrameLayout.LayoutParams hudParams = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.START);
        root.addView(hud, hudParams);
        FrameLayout.LayoutParams controlParams = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        root.addView(controls, controlParams);
        setContentView(root);
    }

    private void loadSampleTrack() {
        try {
            String json = readAsset("SampleTrack.json");
            JSONObject object = new JSONObject(json);
            JSONArray array = object.getJSONArray("points");
            List<TrackPoint> points = new ArrayList<>();
            for (int index = 0; index < array.length(); index++) {
                JSONObject point = array.getJSONObject(index);
                points.add(new TrackPoint(
                        point.getDouble("latitude"),
                        point.getDouble("longitude"),
                        point.optDouble("speed", 50),
                        point.optString("color", "green")
                ));
            }
            overlay.setTrack(points);
            status.setText(object.optString("trackName", "GoKartARLine Android") + " · " + points.size() + "点");
        } catch (Exception error) {
            status.setText("读取示例赛道失败：" + error.getMessage());
        }
    }

    private String readAsset(String name) throws Exception {
        try (InputStream input = getAssets().open(name); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
            return output.toString(StandardCharsets.UTF_8.name());
        }
    }

    private void startCameraWhenReady() {
        cameraPreview.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            @Override public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) { openCamera(surface); }
            @Override public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) { }
            @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) { return true; }
            @Override public void onSurfaceTextureUpdated(SurfaceTexture surface) { }
        });
        if (cameraPreview.isAvailable()) {
            openCamera(cameraPreview.getSurfaceTexture());
        }
    }

    private void openCamera(SurfaceTexture surfaceTexture) {
        try {
            CameraManager manager = (CameraManager) getSystemService(CAMERA_SERVICE);
            String cameraId = findBackCamera(manager);
            if (cameraId == null || checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) { return; }
            surfaceTexture.setDefaultBufferSize(1280, 720);
            manager.openCamera(cameraId, new CameraDevice.StateCallback() {
                @Override public void onOpened(CameraDevice camera) {
                    cameraDevice = camera;
                    startPreview(surfaceTexture);
                }
                @Override public void onDisconnected(CameraDevice camera) { camera.close(); }
                @Override public void onError(CameraDevice camera, int error) { camera.close(); status.setText("相机启动失败：" + error); }
            }, null);
        } catch (Exception error) {
            status.setText("相机启动失败：" + error.getMessage());
        }
    }

    private String findBackCamera(CameraManager manager) throws CameraAccessException {
        for (String id : manager.getCameraIdList()) {
            Integer facing = manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING);
            if (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK) { return id; }
        }
        return manager.getCameraIdList().length > 0 ? manager.getCameraIdList()[0] : null;
    }

    private void startPreview(SurfaceTexture texture) {
        try {
            Surface surface = new Surface(texture);
            CaptureRequest.Builder builder = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            builder.addTarget(surface);
            cameraDevice.createCaptureSession(Arrays.asList(surface), new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession session) {
                    cameraSession = session;
                    try {
                        session.setRepeatingRequest(builder.build(), null, null);
                    } catch (CameraAccessException error) {
                        status.setText("预览失败：" + error.getMessage());
                    }
                }
                @Override public void onConfigureFailed(CameraCaptureSession session) { status.setText("预览配置失败"); }
            }, null);
        } catch (Exception error) {
            status.setText("预览失败：" + error.getMessage());
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (cameraSession != null) { cameraSession.close(); }
        if (cameraDevice != null) { cameraDevice.close(); }
    }

    static final class TrackPoint {
        final double latitude;
        final double longitude;
        final double speed;
        final String color;

        TrackPoint(double latitude, double longitude, double speed, String color) {
            this.latitude = latitude;
            this.longitude = longitude;
            this.speed = speed;
            this.color = color;
        }
    }

    static final class DrivingLineOverlay extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private List<TrackPoint> track = new ArrayList<>();
        private double renderDistance = 120;
        private float verticalOffset = 0;

        DrivingLineOverlay(Context context) {
            super(context);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
            paint.setStrokeWidth(18);
        }

        void setTrack(List<TrackPoint> track) {
            this.track = track;
            invalidate();
        }

        double getRenderDistance() { return renderDistance; }
        void setRenderDistance(double renderDistance) { this.renderDistance = renderDistance; invalidate(); }
        float getVerticalOffset() { return verticalOffset; }
        void setVerticalOffset(float verticalOffset) { this.verticalOffset = verticalOffset; invalidate(); }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            if (track.size() < 2) { return; }
            List<PointF> points = projectTrack();
            for (int index = 0; index < points.size() - 1; index++) {
                float alpha = index < points.size() * 0.45f ? 0.82f : Math.max(0.1f, 1f - (index / (float) points.size()));
                paint.setColor(colorFor(track.get(index % track.size()).color, alpha));
                canvas.drawLine(points.get(index).x, points.get(index).y + verticalOffset, points.get(index + 1).x, points.get(index + 1).y + verticalOffset, paint);
            }
        }

        private List<PointF> projectTrack() {
            TrackPoint origin = track.get(0);
            double latScale = 111_320.0;
            double lonScale = Math.max(Math.cos(Math.toRadians(origin.latitude)) * 111_320.0, 1.0);
            double metersPerPixel = Math.max(renderDistance / Math.max(getHeight() * 0.72, 1), 0.1);
            float centerX = getWidth() / 2f;
            float startY = getHeight() * 0.86f;
            List<PointF> result = new ArrayList<>();
            double distance = 0;
            for (int index = 0; index < track.size() && distance <= renderDistance; index++) {
                TrackPoint point = track.get(index);
                double east = (point.longitude - origin.longitude) * lonScale;
                double north = (point.latitude - origin.latitude) * latScale;
                float x = centerX + (float) (east / metersPerPixel);
                float y = startY - (float) (Math.abs(north) / metersPerPixel);
                if (index > 0) {
                    distance += distanceMeters(track.get(index - 1), point);
                }
                result.add(new PointF(x, y));
            }
            if (result.size() < 2) {
                Path fallback = new Path();
                fallback.moveTo(centerX, startY);
                result.add(new PointF(centerX, startY));
                result.add(new PointF(centerX, startY - getHeight() * 0.55f));
            }
            return result;
        }

        private int colorFor(String color, float alpha) {
            int a = Math.min(255, Math.max(0, (int) (alpha * 255)));
            if ("red".equals(color)) { return Color.argb(a, 255, 0, 0); }
            if ("orange".equals(color)) { return Color.argb(a, 255, 210, 0); }
            return Color.argb(a, 0, 255, 70);
        }

        private double distanceMeters(TrackPoint a, TrackPoint b) {
            double dLat = Math.toRadians(b.latitude - a.latitude);
            double dLon = Math.toRadians(b.longitude - a.longitude);
            double lat1 = Math.toRadians(a.latitude);
            double lat2 = Math.toRadians(b.latitude);
            double h = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                    + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
            return 6_371_000.0 * 2.0 * Math.atan2(Math.sqrt(h), Math.sqrt(1.0 - h));
        }
    }
}
