package com.example.gokartarline;

import android.Manifest;
import android.animation.*;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.graphics.drawable.*;
import android.graphics.SurfaceTexture;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.camera2.*;
import android.location.*;
import android.media.*;
import android.media.projection.*;
import android.net.Uri;
import android.os.*;
import android.text.InputType;
import android.util.Base64;
import android.view.*;
import android.view.animation.*;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.regex.*;

public class MainActivity extends Activity {
    private static final int REQ_PERM = 7, REQ_IMPORT = 8, REQ_IMAGE = 9, REQ_RECORD = 10;
    private static final String DEFAULT_ONLINE_BASE_URL = "http://cheap-host1.cheapyun.com:16781";
    private FrameLayout rootView;
    private TextureView cameraPreview;
    private DrivingLineOverlay overlay;
    private TextView hintText, speedValue, brakeValue, lineDeviationValue, gpsValue;
    private Button recordButton;
    private CameraDevice cameraDevice;
    private CameraCaptureSession cameraSession;
    private android.location.LocationManager locationService;
    private LocationListener locationListener;
    private Location latestLocation;
    private SensorManager sensorManager;
    private SensorEventListener accelerationListener;
    private float latestAccelerationX = 0f;
    private float latestAccelerationY = 0f;
    private float latestAccelerationZ = 0f;
    private SharedPreferences prefs;
    private final ArrayList<TrackData> tracks = new ArrayList<>();
    private int selectedTrack = -1;
    private double renderDistance = 90;
    private double lineOpacity = 0.82;
    private double lineWidth = 0.5;
    private double lineBrightness = 1.0;
    private float lineHeight = 3;
    private boolean lowHeatMode = true;
    private boolean powerSavingMode = false;
    private boolean disableDepthTest = true;
    private boolean metricUnits = true;
    private int gpsAccuracyIndex = 0;
    private boolean isMainScreen = true;
    private boolean isRecording = false;
    private MediaProjectionManager projectionManager;
    private MediaProjection mediaProjection;
    private MediaRecorder mediaRecorder;
    private VirtualDisplay virtualDisplay;
    private File recordingFile;
    private Bitmap selectedAIImage;
    private PointF selectedAIFinishPoint;
    private final ArrayList<PointF> aiDrawnPoints = new ArrayList<>();
    private ImagePointView aiImageView;
    private TextView aiMessage;
    private AlertDialog activeDialog;
    private String onlineBaseUrl;
    private String onlineToken;
    private String onlineUsername;
    private String onlineEmail;
    private String lapTrackRemoteId;
    private long lapStartedAt = 0;
    private long lastLapSampleAt = 0;
    private boolean wasNearStart = false;
    private final ArrayList<TelemetrySample> lapSamples = new ArrayList<>();

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("gokart", MODE_PRIVATE);
        renderDistance = Double.longBitsToDouble(prefs.getLong("renderDistance", Double.doubleToRawLongBits(90)));
        lineOpacity = Double.longBitsToDouble(prefs.getLong("lineOpacity", Double.doubleToRawLongBits(0.82)));
        lineWidth = Double.longBitsToDouble(prefs.getLong("lineWidth", Double.doubleToRawLongBits(0.5)));
        lineBrightness = Double.longBitsToDouble(prefs.getLong("lineBrightness", Double.doubleToRawLongBits(1.0)));
        lineHeight = prefs.getFloat("lineHeight", 3);
        lowHeatMode = prefs.getBoolean("lowHeat", true);
        powerSavingMode = prefs.getBoolean("powerSaving", false);
        disableDepthTest = prefs.getBoolean("disableDepthTest", true);
        metricUnits = prefs.getBoolean("metricUnits", true);
        gpsAccuracyIndex = prefs.getInt("gpsAccuracy", 0);
        onlineBaseUrl = prefs.getString("onlineBaseUrl", DEFAULT_ONLINE_BASE_URL);
        onlineToken = prefs.getString("onlineToken", "");
        onlineUsername = prefs.getString("onlineUsername", "");
        onlineEmail = prefs.getString("onlineEmail", "");
        projectionManager = (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        loadTracks();
        buildMainUi();
        if (tracks.isEmpty()) loadSampleTrack(); else selectTrack(Math.max(0, prefs.getInt("selectedTrack", 0)));
        requestCameraIfNeeded();
        startLocationUpdatesIfAllowed();
        startAccelerationUpdates();
    }

    private void buildMainUi() {
        isMainScreen = true;
        rootView = new FrameLayout(this);
        rootView.setBackgroundColor(Color.BLACK);
        cameraPreview = new TextureView(this);
        cameraPreview.setOpaque(true);
        cameraPreview.setAlpha(1f);
        overlay = new DrivingLineOverlay(this);
        overlay.setRenderDistance(renderDistance);
        overlay.setVerticalOffset(lineHeight);
        overlay.setLineStyle(lineOpacity, lineWidth, lineBrightness);
        rootView.addView(cameraPreview, new FrameLayout.LayoutParams(-1, -1));
        rootView.addView(overlay, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout hud = new LinearLayout(this);
        hud.setOrientation(LinearLayout.VERTICAL);
        hud.setGravity(Gravity.CENTER);
        hintText = new TextView(this);
        hintText.setText("请导入赛道");
        hintText.setTextColor(Color.WHITE);
        hintText.setTextSize(34);
        hintText.setTypeface(Typeface.DEFAULT_BOLD);
        hintText.setGravity(Gravity.CENTER);
        hintText.setShadowLayer(dp(6), 0, dp(1), Color.argb(180, 0, 0, 0));
        hud.addView(hintText, new LinearLayout.LayoutParams(-2, -2));
        LinearLayout metrics = new LinearLayout(this);
        metrics.setGravity(Gravity.CENTER);
        metrics.setPadding(0, dp(8), 0, 0);
        speedValue = addMetricCard(metrics, "车速");
        brakeValue = addMetricCard(metrics, "刹车点");
        lineDeviationValue = addMetricCard(metrics, "偏离");
        gpsValue = addMetricCard(metrics, "GPS");
        hud.addView(metrics, new LinearLayout.LayoutParams(-2, -2));
        FrameLayout.LayoutParams hudParams = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        hudParams.setMargins(dp(14), dp(14), dp(14), dp(14));
        rootView.addView(hud, hudParams);

        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER);
        bar.setPadding(0, 0, 0, 0);
        addButton(bar, "导入", v -> importTrack());
        addButton(bar, "赛道", v -> showTrackList());
        addButton(bar, "在线", v -> showOnlineCenter());
        addButton(bar, "校准", v -> manualCalibrate());
        recordButton = addButton(bar, isRecording ? "停止" : "录屏", v -> toggleRecording());
        addButton(bar, "截图", v -> captureStillImage());
        addButton(bar, "设置", v -> showSettings());
        FrameLayout.LayoutParams barParams = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        barParams.setMargins(dp(18), dp(18), dp(18), dp(18));
        rootView.addView(bar, barParams);
        setContentView(rootView);
        animateChildrenStaggered(bar);
        updateHud();
    }

    private TextView addMetricCard(LinearLayout parent, String title) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER);
        card.setPadding(dp(14), dp(8), dp(14), dp(8));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.argb(140, 0, 0, 0));
        bg.setCornerRadius(dp(14));
        card.setBackground(bg);
        TextView label = new TextView(this);
        label.setText(title);
        label.setTextColor(Color.argb(184, 255, 255, 255));
        label.setTextSize(12);
        label.setGravity(Gravity.CENTER);
        TextView value = new TextView(this);
        value.setText("--");
        value.setTextColor(Color.WHITE);
        value.setTextSize(18);
        value.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        value.setGravity(Gravity.CENTER);
        card.addView(label);
        card.addView(value);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.setMargins(dp(8), 0, dp(8), 0);
        parent.addView(card, lp);
        return value;
    }

    private Button addButton(LinearLayout parent, String text, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setText(text);
        applyGlassButton(b);
        b.setOnClickListener(listener);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, dp(56));
        lp.setMargins(dp(6), 0, dp(6), 0);
        parent.addView(b, lp);
        return b;
    }


    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private Drawable glassPanel(float radiusDp, int alpha) {
        return new GlassPanelDrawable(dp(radiusDp), alpha);
    }

    private Drawable mnsjGlowBackground(String coreColorHex, float cornerRadiusDp, int strokeWidthDp, String strokeColorHex) {
        int glowWidth = dp(7);
        int layersCount = 4;
        Drawable[] layers = new Drawable[layersCount + 1];
        float radius = dp(cornerRadiusDp);
        for (int i = 0; i < layersCount; i++) {
            GradientDrawable glowLayer = new GradientDrawable();
            glowLayer.setColor(Color.argb((int) (255 * (0.015f + 0.01f * i)), 220, 230, 245));
            glowLayer.setCornerRadius(radius + (layersCount - i) * dp(1.5f));
            layers[i] = glowLayer;
        }
        GradientDrawable core = new GradientDrawable();
        core.setColor(Color.parseColor(coreColorHex));
        core.setCornerRadius(radius);
        if (strokeWidthDp > 0) core.setStroke(dp(strokeWidthDp), Color.parseColor(strokeColorHex));
        layers[layersCount] = core;
        LayerDrawable layerDrawable = new LayerDrawable(layers);
        for (int i = 0; i < layersCount; i++) {
            int inset = (int) (glowWidth * ((float) i / layersCount));
            layerDrawable.setLayerInset(i, inset, inset, inset, inset);
        }
        layerDrawable.setLayerInset(layersCount, glowWidth, glowWidth, glowWidth, glowWidth);
        return layerDrawable;
    }

    private Drawable mnsjButtonBackground(boolean pressed) {
        return mnsjGlowBackground(pressed ? "#242424" : "#151515", 25, 1, pressed ? "#9C5F54" : "#2C2C2C");
    }

    private Drawable mnsjControlBackground() {
        return mnsjGlowBackground("#1C1C1C", 24, 1, "#333333");
    }

    private LinearLayout glassContainer(float radiusDp, int alpha) {
        LinearLayout layout = new LinearLayout(this);
        layout.setBackground(mnsjGlowBackground("#151515", radiusDp, 1, "#2C2C2C"));
        layout.setElevation(dp(10));
        return layout;
    }

    private void applyGlassButton(Button button) {
        button.setAllCaps(false);
        button.setTextColor(Color.WHITE);
        button.setTextSize(14);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setMinHeight(dp(48));
        button.setMinWidth(dp(108));
        button.setPadding(dp(18), 0, dp(18), 0);
        StateListDrawable states = new StateListDrawable();
        states.addState(new int[]{android.R.attr.state_pressed}, mnsjButtonBackground(true));
        states.addState(new int[]{}, mnsjButtonBackground(false));
        button.setBackground(states);
        button.setElevation(dp(12));
        button.setOnTouchListener((view, event) -> {
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
                view.animate().scaleX(0.94f).scaleY(0.94f).alpha(0.86f).setDuration(90).setInterpolator(new DecelerateInterpolator()).start();
            } else if (event.getAction() == MotionEvent.ACTION_UP || event.getAction() == MotionEvent.ACTION_CANCEL) {
                view.animate().scaleX(1f).scaleY(1f).alpha(1f).setDuration(180).setInterpolator(new OvershootInterpolator(1.4f)).start();
            }
            return false;
        });
    }

    private AlertDialog showGlassDialog(AlertDialog dialog) {
        pauseCamera();
        dialog.setOnShowListener(d -> {
            Window window = dialog.getWindow();
            if (window != null) {
                window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
                View decor = window.getDecorView();
                decor.setPadding(dp(12), dp(12), dp(12), dp(12));
                decor.setBackground(mnsjGlowBackground("#1A1A1A", 36, 1, "#2A2A2A"));
                decor.setElevation(dp(22));
                animateDialogIn(decor);
            }
            Button positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            Button negative = dialog.getButton(AlertDialog.BUTTON_NEGATIVE);
            Button neutral = dialog.getButton(AlertDialog.BUTTON_NEUTRAL);
            if (positive != null) applyGlassButton(positive);
            if (negative != null) applyGlassButton(negative);
            if (neutral != null) applyGlassButton(neutral);
        });
        dialog.setOnDismissListener(d -> { activeDialog = null; resumeCameraIfMain(); });
        dialog.show();
        activeDialog = dialog;
        return dialog;
    }

    private void animateDialogIn(View view) {
        view.setAlpha(0f);
        view.setScaleX(0.72f);
        view.setScaleY(0.72f);
        view.setRotationX(-18f);
        view.setCameraDistance(8000 * getResources().getDisplayMetrics().density);
        AnimatorSet set = new AnimatorSet();
        set.playTogether(
                ObjectAnimator.ofFloat(view, "alpha", 0f, 1f),
                ObjectAnimator.ofFloat(view, "scaleX", 0.72f, 1f),
                ObjectAnimator.ofFloat(view, "scaleY", 0.72f, 1f),
                ObjectAnimator.ofFloat(view, "rotationX", -18f, 0f));
        set.setDuration(520);
        set.setInterpolator(new OvershootInterpolator(1.15f));
        set.start();
    }

    private void animateChildrenStaggered(ViewGroup parent) {
        parent.post(() -> {
            for (int i = 0; i < parent.getChildCount(); i++) {
                View child = parent.getChildAt(i);
                child.setAlpha(0f);
                child.setTranslationX(dp(80));
                child.setScaleX(0.96f);
                child.setScaleY(0.96f);
                child.animate()
                        .translationX(0f)
                        .alpha(1f)
                        .scaleX(1f)
                        .scaleY(1f)
                        .setStartDelay(i * 45L)
                        .setDuration(280)
                        .setInterpolator(new DecelerateInterpolator(1.6f))
                        .start();
            }
        });
    }

    private LayoutTransition mnsjLayoutTransition() {
        LayoutTransition transition = new LayoutTransition();
        transition.enableTransitionType(LayoutTransition.CHANGING);
        transition.setDuration(240);
        return transition;
    }

    private LinearLayout glassDialogBox() {
        LinearLayout box = glassContainer(32, 14);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(24), dp(18), dp(24), dp(12));
        box.setLayoutTransition(mnsjLayoutTransition());
        return box;
    }

    private void requestCameraIfNeeded() {
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA, Manifest.permission.ACCESS_FINE_LOCATION}, REQ_PERM);
        } else startCameraWhenReady();
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(requestCode, permissions, grants);
        if (requestCode == REQ_PERM && grants.length > 0 && grants[0] == PackageManager.PERMISSION_GRANTED) startCameraWhenReady();
        else showNoCameraBackground("无相机权限：预览模式");
        startLocationUpdatesIfAllowed();
    }

    private void showNoCameraBackground(String message) {
        cameraPreview.setBackgroundColor(Color.rgb(18, 18, 18));
        toast(message);
        updateHud();
    }

    private void setStatus(String message) {
        toast(message);
        updateHud();
    }

    private void updateHud() {
        if (hintText == null || speedValue == null || brakeValue == null || lineDeviationValue == null || gpsValue == null) return;
        TrackPoint nearest = nearestTrackPoint();
        String hint = selectedTrack >= 0 ? drivingHint(nearest == null ? "green" : nearest.color) : "请导入赛道";
        hintText.setText(hint);
        hintText.setTextColor(colorForHint(nearest == null ? "green" : nearest.color));
        double speed = latestLocation != null && latestLocation.hasSpeed() ? Math.max(latestLocation.getSpeed(), 0) : 0;
        speedValue.setText(metricUnits ? ((int) (speed * 3.6)) + " km/h" : ((int) (speed * 2.23694)) + " mph");
        brakeValue.setText(brakingDistanceText());
        lineDeviationValue.setText(lineDeviationText());
        gpsValue.setText(latestLocation != null && latestLocation.hasAccuracy() ? "±" + (int) latestLocation.getAccuracy() + "m" : "--");
    }

    private String brakingDistanceText() {
        if (latestLocation == null || selectedTrack < 0 || selectedTrack >= tracks.size()) return "--";
        double best = Double.MAX_VALUE;
        TrackPoint current = new TrackPoint(latestLocation.getLatitude(), latestLocation.getLongitude(), 0, "green");
        for (TrackPoint point : tracks.get(selectedTrack).points) {
            if (!"red".equals(point.color)) continue;
            best = Math.min(best, distanceMeters(current, point));
        }
        return best == Double.MAX_VALUE ? "--" : ((int) best) + " m";
    }

    private String lineDeviationText() {
        if (latestLocation == null || selectedTrack < 0 || selectedTrack >= tracks.size()) return "--";
        return ((int) lineDeviationMeters(latestLocation, tracks.get(selectedTrack))) + " m";
    }

    private TrackPoint nearestTrackPoint() {
        if (selectedTrack < 0 || selectedTrack >= tracks.size() || tracks.get(selectedTrack).points.isEmpty()) return null;
        if (latestLocation == null) return tracks.get(selectedTrack).points.get(0);
        TrackPoint current = new TrackPoint(latestLocation.getLatitude(), latestLocation.getLongitude(), 0, "green");
        TrackPoint nearest = null;
        double best = Double.MAX_VALUE;
        for (TrackPoint point : tracks.get(selectedTrack).points) {
            double distance = distanceMeters(current, point);
            if (distance < best) { best = distance; nearest = point; }
        }
        return nearest;
    }

    private String drivingHint(String color) {
        if ("red".equals(color)) return "刹车";
        if ("orange".equals(color)) return "松油";
        return "全油门";
    }

    private int colorForHint(String color) {
        if ("red".equals(color)) return Color.rgb(255, 24, 16);
        if ("orange".equals(color)) return Color.rgb(255, 156, 0);
        return Color.rgb(0, 255, 70);
    }

    private void importTrack() {
        pauseCamera();
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
        startActivityForResult(intent, REQ_IMPORT);
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_IMPORT && resultCode == RESULT_OK && data != null) {
            try { addTrack(parseImportedTrack(readUri(data.getData()), "导入赛道")); toast("导入成功"); }
            catch (Exception e) { toast("导入失败：" + e.getMessage()); }
            resumeCameraIfMain();
        } else if (requestCode == REQ_IMPORT) {
            resumeCameraIfMain();
        } else if (requestCode == REQ_IMAGE && resultCode == RESULT_OK && data != null) {
            loadAIImage(data.getData());
        } else if (requestCode == REQ_RECORD) {
            if (resultCode == RESULT_OK && data != null) startScreenRecording(resultCode, data);
            else toast("录屏授权已取消");
        }
    }

    private String readUri(Uri uri) throws Exception { try (InputStream in = getContentResolver().openInputStream(uri)) { return readStream(in); } }
    private String readAsset(String name) throws Exception { try (InputStream in = getAssets().open(name)) { return readStream(in); } }
    private String readStream(InputStream in) throws Exception { ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] b = new byte[8192]; int n; while ((n = in.read(b)) != -1) out.write(b, 0, n); return out.toString(StandardCharsets.UTF_8.name()); }

    private void loadSampleTrack() { try { addTrack(parseTrack(readAsset("SampleTrack.json"), "示例赛道")); } catch (Exception e) { toast("示例赛道读取失败：" + e.getMessage()); } }

    private TrackData parseImportedTrack(String raw, String fallbackName) throws Exception {
        String trimmed = raw.trim();
        if (trimmed.startsWith("<")) return parseGpxTrack(trimmed, fallbackName);
        return parseTrack(trimmed, fallbackName);
    }

    private TrackData parseGpxTrack(String xml, String fallbackName) throws Exception {
        TrackData t = new TrackData();
        t.name = fallbackName;
        Matcher matcher = Pattern.compile("<(?:trkpt|rtept)[^>]*lat=\"([^\"]+)\"[^>]*lon=\"([^\"]+)\"", Pattern.CASE_INSENSITIVE).matcher(xml);
        while (matcher.find()) t.points.add(new TrackPoint(Double.parseDouble(matcher.group(1)), Double.parseDouble(matcher.group(2)), 50, "green"));
        if (t.points.size() < 2) throw new IOException("GPX没有有效轨迹点");
        t.length = computeLength(t.points);
        return t;
    }

    private TrackData parseTrack(String json, String fallbackName) throws Exception {
        JSONObject obj = new JSONObject(json);
        TrackData t = new TrackData();
        t.remoteId = obj.optString("remoteID", obj.optString("remoteId", ""));
        t.name = obj.optString("trackName", fallbackName);
        t.length = obj.optDouble("trackLength", 0);
        t.cornerCount = obj.optInt("cornerCount", 0);
        JSONArray arr = obj.getJSONArray("points");
        for (int i = 0; i < arr.length(); i++) {
            JSONObject p = arr.getJSONObject(i);
            t.points.add(new TrackPoint(p.getDouble("latitude"), p.getDouble("longitude"), p.optDouble("speed", 50), p.optString("color", "green")));
        }
        if (t.length <= 0) t.length = computeLength(t.points);
        return t;
    }

    private void addTrack(TrackData track) { tracks.add(track); selectedTrack = tracks.size() - 1; saveTracks(); selectTrack(selectedTrack); }
    private void selectTrack(int index) { if (index < 0 || index >= tracks.size()) return; selectedTrack = index; overlay.setTrack(tracks.get(index).points); prefs.edit().putInt("selectedTrack", index).apply(); updateHud(); }

    private void startLocationUpdatesIfAllowed() {
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) return;
        if (locationService == null) locationService = (android.location.LocationManager) getSystemService(LOCATION_SERVICE);
        if (locationListener == null) {
            locationListener = new LocationListener() {
                @Override public void onLocationChanged(Location location) { latestLocation = location; updateHud(); handleLapTelemetry(location); }
                @Override public void onStatusChanged(String provider, int status, Bundle extras) {}
                @Override public void onProviderEnabled(String provider) {}
                @Override public void onProviderDisabled(String provider) {}
            };
        }
        try {
            locationService.removeUpdates(locationListener);
            String provider = locationService.isProviderEnabled(android.location.LocationManager.GPS_PROVIDER) ? android.location.LocationManager.GPS_PROVIDER : android.location.LocationManager.NETWORK_PROVIDER;
            long interval = gpsAccuracyIndex == 0 ? 250 : gpsAccuracyIndex == 1 ? 500 : 1500;
            float distance = gpsAccuracyIndex == 2 ? 10f : 0f;
            locationService.requestLocationUpdates(provider, interval, distance, locationListener);
            latestLocation = locationService.getLastKnownLocation(provider);
            updateHud();
        } catch (Exception e) { toast("定位失败：" + e.getMessage()); }
    }

    private void startAccelerationUpdates() {
        if (sensorManager == null) sensorManager = (SensorManager) getSystemService(SENSOR_SERVICE);
        if (sensorManager == null) return;
        Sensor sensor = sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION);
        if (sensor == null) sensor = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        if (sensor == null) return;
        if (accelerationListener == null) {
            accelerationListener = new SensorEventListener() {
                @Override public void onSensorChanged(SensorEvent event) {
                    if (event.values.length < 3) return;
                    latestAccelerationX = event.values[0];
                    latestAccelerationY = event.values[1];
                    latestAccelerationZ = event.sensor.getType() == Sensor.TYPE_ACCELEROMETER ? event.values[2] - SensorManager.GRAVITY_EARTH : event.values[2];
                }
                @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {}
            };
        }
        sensorManager.unregisterListener(accelerationListener);
        sensorManager.registerListener(accelerationListener, sensor, SensorManager.SENSOR_DELAY_GAME);
    }

    private void stopAccelerationUpdates() {
        if (sensorManager != null && accelerationListener != null) sensorManager.unregisterListener(accelerationListener);
    }

    private void pauseCamera() {
        try { if (cameraSession != null) cameraSession.close(); } catch (Exception ignored) {}
        try { if (cameraDevice != null) cameraDevice.close(); } catch (Exception ignored) {}
        cameraSession = null;
        cameraDevice = null;
    }

    private void resumeCameraIfMain() {
        if (isMainScreen && cameraPreview != null) startCameraWhenReady();
    }

    private void manualCalibrate() {
        if (selectedTrack < 0 || selectedTrack >= tracks.size()) { toast("没有可用于校准的赛道"); return; }
        if (latestLocation != null) toast("已按当前位置手动校准");
        else toast("已按赛道起点校准");
        updateHud();
    }

    private void captureStillImage() {
        if (rootView == null || rootView.getWidth() <= 0 || rootView.getHeight() <= 0) return;
        try {
            Bitmap bitmap = Bitmap.createBitmap(rootView.getWidth(), rootView.getHeight(), Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            Bitmap camera = cameraPreview != null ? cameraPreview.getBitmap() : null;
            if (camera != null) canvas.drawBitmap(camera, null, new Rect(0, 0, bitmap.getWidth(), bitmap.getHeight()), null);
            overlay.draw(canvas);
            File dir = getExternalFilesDir(Environment.DIRECTORY_PICTURES);
            if (dir != null && !dir.exists()) dir.mkdirs();
            File file = new File(dir, "GoKartARLine-" + System.currentTimeMillis() + ".png");
            try (FileOutputStream out = new FileOutputStream(file)) { bitmap.compress(Bitmap.CompressFormat.PNG, 100, out); }
            MediaScannerConnection.scanFile(this, new String[]{file.getAbsolutePath()}, new String[]{"image/png"}, null);
            toast("截图已保存：" + file.getName());
        } catch (Exception e) { toast("截图失败：" + e.getMessage()); }
    }

    private void toggleRecording() {
        if (isRecording) stopScreenRecordingIfNeeded();
        else startActivityForResult(projectionManager.createScreenCaptureIntent(), REQ_RECORD);
    }

    private void startScreenRecording(int resultCode, Intent data) {
        try {
            android.util.DisplayMetrics metrics = getResources().getDisplayMetrics();
            int width = Math.max(1280, metrics.widthPixels);
            int height = Math.max(720, metrics.heightPixels);
            File dir = getExternalFilesDir(Environment.DIRECTORY_MOVIES);
            if (dir != null && !dir.exists()) dir.mkdirs();
            recordingFile = new File(dir, "GoKartARLine-" + System.currentTimeMillis() + ".mp4");
            mediaRecorder = new MediaRecorder();
            mediaRecorder.setVideoSource(MediaRecorder.VideoSource.SURFACE);
            mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            mediaRecorder.setOutputFile(recordingFile.getAbsolutePath());
            mediaRecorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264);
            mediaRecorder.setVideoSize(width, height);
            mediaRecorder.setVideoFrameRate(powerSavingMode ? 30 : 60);
            mediaRecorder.setVideoEncodingBitRate(10_000_000);
            mediaRecorder.prepare();
            mediaProjection = projectionManager.getMediaProjection(resultCode, data);
            virtualDisplay = mediaProjection.createVirtualDisplay("GoKartARLineRecording", width, height, metrics.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, mediaRecorder.getSurface(), null, null);
            mediaRecorder.start();
            isRecording = true;
            if (recordButton != null) recordButton.setText("停止");
            toast("开始录屏");
        } catch (Exception e) {
            stopScreenRecordingIfNeeded();
            toast("开始录屏失败：" + e.getMessage());
        }
    }

    private void stopScreenRecordingIfNeeded() {
        if (!isRecording && mediaRecorder == null && mediaProjection == null) return;
        try { if (mediaRecorder != null) mediaRecorder.stop(); } catch (Exception ignored) {}
        try { if (mediaRecorder != null) mediaRecorder.release(); } catch (Exception ignored) {}
        try { if (virtualDisplay != null) virtualDisplay.release(); } catch (Exception ignored) {}
        try { if (mediaProjection != null) mediaProjection.stop(); } catch (Exception ignored) {}
        mediaRecorder = null;
        virtualDisplay = null;
        mediaProjection = null;
        isRecording = false;
        if (recordButton != null) recordButton.setText("录屏");
        if (recordingFile != null) {
            MediaScannerConnection.scanFile(this, new String[]{recordingFile.getAbsolutePath()}, new String[]{"video/mp4"}, null);
            toast("录屏已保存：" + recordingFile.getName());
        }
    }

    private void showOnlineCenter() {
        LinearLayout box = glassDialogBox();

        if (isOnlineLoggedIn()) {
            box.addView(sectionLabel("账号"));
            box.addView(label((onlineUsername == null || onlineUsername.isEmpty() ? "已登录" : onlineUsername) + (onlineEmail == null || onlineEmail.isEmpty() ? "" : " · " + onlineEmail)));
            LinearLayout actions = new LinearLayout(this);
            addButton(actions, "上传当前赛道", v -> uploadSelectedTrack());
            addButton(actions, "分享页", v -> fetchOnlineTracks());
            addButton(actions, "退出", v -> {
                onlineToken = "";
                onlineUsername = "";
                onlineEmail = "";
                prefs.edit().remove("onlineToken").remove("onlineUsername").remove("onlineEmail").apply();
                toast("已退出登录");
            });
            box.addView(actions, new LinearLayout.LayoutParams(-1, dp(62)));
            TextView info = label("下载的共享赛道跑完一圈后，会自动上传圈速、GPS采样并优化服务器赛道。");
            info.setTextColor(Color.argb(180, 255, 255, 255));
            box.addView(info);
        } else {
            box.addView(sectionLabel("登录"));
            TextView hint = label("使用用户名或邮箱登录。没有账号时，进入注册页填写邮箱验证码。");
            hint.setTextSize(14);
            hint.setTextColor(Color.argb(180, 255, 255, 255));
            box.addView(hint);
            EditText login = aiField("用户名或邮箱", "", false);
            EditText loginPassword = aiField("密码", "", true);
            box.addView(login);
            box.addView(loginPassword);
            LinearLayout loginTools = new LinearLayout(this);
            addButton(loginTools, "登录", v -> loginOnline(login.getText().toString(), loginPassword.getText().toString()));
            addButton(loginTools, "注册账号", v -> { closeOpenDialogs(); showRegisterOnlineDialog(); });
            box.addView(loginTools, new LinearLayout.LayoutParams(-1, dp(62)));
        }
        showGlassDialog(new AlertDialog.Builder(this).setTitle("在线").setView(box).setPositiveButton("完成", null).create());
        animateChildrenStaggered(box);
    }

    private void showRegisterOnlineDialog() {
        LinearLayout box = glassDialogBox();
        box.addView(sectionLabel("注册账号"));
        TextView hint = label("像网站注册一样填写用户名、邮箱、密码，再通过邮件验证码完成注册。");
        hint.setTextSize(14);
        hint.setTextColor(Color.argb(180, 255, 255, 255));
        box.addView(hint);
        EditText username = aiField("用户名", "", false);
        EditText email = aiField("邮箱", "", false);
        EditText password = aiField("密码", "", true);
        EditText code = aiField("邮箱验证码", "", false);
        box.addView(username);
        box.addView(email);
        box.addView(password);
        box.addView(code);
        LinearLayout registerTools = new LinearLayout(this);
        addButton(registerTools, "获取验证码", v -> requestOnlineCode(email.getText().toString()));
        addButton(registerTools, "完成注册", v -> registerOnline(username.getText().toString(), password.getText().toString(), email.getText().toString(), code.getText().toString()));
        addButton(registerTools, "返回登录", v -> { closeOpenDialogs(); showOnlineCenter(); });
        box.addView(registerTools, new LinearLayout.LayoutParams(-1, dp(62)));

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(false);
        scroll.addView(box);
        animateChildrenStaggered(box);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("注册").setView(scroll).setPositiveButton("完成", null).create());
    }

    private boolean isOnlineLoggedIn() { return onlineToken != null && !onlineToken.trim().isEmpty(); }

    private String normalizeOnlineBase(String value) {
        String base = value == null ? "" : value.trim();
        while (base.endsWith("/")) base = base.substring(0, base.length() - 1);
        return base.isEmpty() ? DEFAULT_ONLINE_BASE_URL : base;
    }

    private void requestOnlineCode(String email) {
        new Thread(() -> {
            try {
                JSONObject body = new JSONObject().put("email", email.trim());
                JSONObject response = onlineApi("/api/auth/request-code", "POST", body, false);
                runOnUiThread(() -> toast(response.optString("message", response.optBoolean("emailSent") ? "验证码已发送" : "验证码已生成")));
            } catch (Exception e) { runOnUiThread(() -> toast("验证码请求失败：" + e.getMessage())); }
        }).start();
    }

    private void registerOnline(String username, String password, String email, String code) {
        new Thread(() -> {
            try {
                JSONObject body = new JSONObject().put("username", username.trim()).put("password", password).put("email", email.trim()).put("code", code.trim());
                JSONObject response = onlineApi("/api/auth/register", "POST", body, false);
                applyOnlineAuth(response);
                runOnUiThread(() -> { toast("注册并登录成功"); closeOpenDialogs(); showOnlineCenter(); });
            } catch (Exception e) { runOnUiThread(() -> toast("注册失败：" + e.getMessage())); }
        }).start();
    }

    private void loginOnline(String login, String password) {
        new Thread(() -> {
            try {
                JSONObject body = new JSONObject().put("login", login.trim()).put("password", password);
                JSONObject response = onlineApi("/api/auth/login", "POST", body, false);
                applyOnlineAuth(response);
                runOnUiThread(() -> { toast("登录成功"); closeOpenDialogs(); showOnlineCenter(); });
            } catch (Exception e) { runOnUiThread(() -> toast("登录失败：" + e.getMessage())); }
        }).start();
    }

    private void applyOnlineAuth(JSONObject response) throws JSONException {
        onlineToken = response.getString("token");
        JSONObject user = response.getJSONObject("user");
        onlineUsername = user.optString("username", "");
        onlineEmail = user.optString("email", "");
        prefs.edit().putString("onlineToken", onlineToken).putString("onlineUsername", onlineUsername).putString("onlineEmail", onlineEmail).apply();
    }

    private void uploadSelectedTrack() {
        if (!isOnlineLoggedIn()) { toast("请先登录"); return; }
        if (selectedTrack < 0 || selectedTrack >= tracks.size()) { toast("请先选择赛道"); return; }
        TrackData track = tracks.get(selectedTrack);
        new Thread(() -> {
            try {
                JSONObject response = onlineApi("/api/tracks", "POST", trackToJson(track), true);
                track.remoteId = response.optString("remoteID", track.remoteId);
                saveTracks();
                runOnUiThread(() -> toast("已分享：" + track.name));
            } catch (Exception e) { runOnUiThread(() -> toast("分享失败：" + e.getMessage())); }
        }).start();
    }

    private void fetchOnlineTracks() {
        new Thread(() -> {
            try {
                JSONObject response = onlineApi("/api/tracks", "GET", null, false);
                JSONArray arr = response.getJSONArray("tracks");
                runOnUiThread(() -> showOnlineTrackList(arr));
            } catch (Exception e) { runOnUiThread(() -> toast("分享页加载失败：" + e.getMessage())); }
        }).start();
    }

    private void showOnlineTrackList(JSONArray arr) {
        closeOpenDialogs();
        LinearLayout box = glassDialogBox();
        ScrollView scroll = new ScrollView(this);
        LinearLayout rows = new LinearLayout(this);
        rows.setOrientation(LinearLayout.VERTICAL);
        if (arr.length() == 0) rows.addView(label("暂无可下载地图"));
        for (int i = 0; i < arr.length(); i++) {
            JSONObject item = arr.optJSONObject(i);
            if (item == null) continue;
            String id = item.optString("id");
            String name = item.optString("trackName", "共享赛道");
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(dp(12), dp(8), dp(12), dp(8));
            row.setBackground(mnsjGlowBackground("#1C1C1C", 24, 1, "#333333"));
            row.setOnTouchListener((view, event) -> {
                if (event.getAction() == MotionEvent.ACTION_DOWN) view.animate().scaleX(0.985f).scaleY(0.985f).alpha(0.92f).setDuration(90).start();
                else if (event.getAction() == MotionEvent.ACTION_UP || event.getAction() == MotionEvent.ACTION_CANCEL) view.animate().scaleX(1f).scaleY(1f).alpha(1f).setDuration(180).setInterpolator(new OvershootInterpolator(1.2f)).start();
                return false;
            });
            LinearLayout texts = new LinearLayout(this);
            texts.setOrientation(LinearLayout.VERTICAL);
            TextView title = label(name);
            title.setTypeface(Typeface.DEFAULT_BOLD);
            TextView meta = label((int) item.optDouble("trackLength", 0) + "m · " + item.optInt("cornerCount") + "弯 · " + item.optInt("pointCount") + "点 · " + item.optString("authorName"));
            meta.setTextSize(13);
            meta.setTextColor(Color.argb(170, 255, 255, 255));
            texts.addView(title);
            texts.addView(meta);
            row.addView(texts, new LinearLayout.LayoutParams(0, -2, 1));
            addButton(row, "下载导入", v -> downloadOnlineTrack(id));
            addButton(row, "排行榜", v -> showLeaderboard(id, name));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
            lp.setMargins(0, dp(6), 0, dp(6));
            rows.addView(row, lp);
        }
        scroll.addView(rows);
        box.addView(scroll, new LinearLayout.LayoutParams(-1, dp(430)));
        animateChildrenStaggered(rows);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("分享页").setView(box).setPositiveButton("完成", null).create());
    }

    private void downloadOnlineTrack(String remoteId) {
        new Thread(() -> {
            try {
                JSONObject response = onlineApi("/api/tracks/" + URLEncoder.encode(remoteId, "UTF-8") + "/download", "GET", null, false);
                TrackData track = parseTrack(response.getJSONObject("track").toString(), "共享赛道");
                if (track.remoteId == null || track.remoteId.isEmpty()) track.remoteId = remoteId;
                runOnUiThread(() -> { addTrack(track); toast("已下载并导入：" + track.name); closeOpenDialogs(); });
            } catch (Exception e) { runOnUiThread(() -> toast("下载失败：" + e.getMessage())); }
        }).start();
    }

    private void showLeaderboard(String remoteId, String trackName) {
        new Thread(() -> {
            try {
                JSONObject response = onlineApi("/api/tracks/" + URLEncoder.encode(remoteId, "UTF-8") + "/leaderboard", "GET", null, false);
                JSONArray board = response.getJSONArray("leaderboard");
                runOnUiThread(() -> showLeaderboardDialog(trackName, board));
            } catch (Exception e) { runOnUiThread(() -> toast("排行榜加载失败：" + e.getMessage())); }
        }).start();
    }

    private void showLeaderboardDialog(String trackName, JSONArray board) {
        closeOpenDialogs();
        LinearLayout box = glassDialogBox();
        if (board.length() == 0) {
            box.addView(label("暂无圈速"));
        } else {
            for (int i = 0; i < board.length(); i++) {
                JSONObject item = board.optJSONObject(i);
                if (item == null) continue;
                TextView row = label("#" + item.optInt("rank") + "  " + item.optString("username") + "  " + formatLapTime(item.optInt("lapTimeMs")) + "  " + (int) item.optDouble("speedKph") + " km/h  GPS ±" + (int) item.optDouble("gpsAccuracy") + "m"
                        + "\n油门 " + item.optInt("throttleScore") + "%  刹车 " + item.optInt("brakeScore") + "%  偏离 " + String.format(Locale.US, "%.1fm", item.optDouble("lineDeviationAvg")));
                row.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
                box.addView(row);
            }
        }
        animateChildrenStaggered(box);
        showGlassDialog(new AlertDialog.Builder(this).setTitle(trackName + " 排行榜").setView(box).setPositiveButton("完成", null).create());
    }

    private JSONObject onlineApi(String path, String method, JSONObject body, boolean auth) throws Exception {
        URL url = new URL(normalizeOnlineBase(onlineBaseUrl) + path);
        HttpURLConnection con = (HttpURLConnection) url.openConnection();
        con.setRequestMethod(method);
        con.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        con.setConnectTimeout(15000);
        con.setReadTimeout(25000);
        if (auth) con.setRequestProperty("Authorization", "Bearer " + onlineToken);
        if (body != null && !"GET".equals(method)) {
            con.setDoOutput(true);
            con.getOutputStream().write(body.toString().getBytes(StandardCharsets.UTF_8));
        }
        int code = con.getResponseCode();
        InputStream stream = code >= 200 && code < 300 ? con.getInputStream() : con.getErrorStream();
        String raw = stream != null ? readStream(stream) : "";
        JSONObject response = raw.trim().isEmpty() ? new JSONObject() : new JSONObject(raw);
        if (code < 200 || code >= 300) throw new IOException(response.optString("error", "服务器错误 " + code));
        return response;
    }

    private JSONObject trackToJson(TrackData track) throws JSONException {
        JSONObject body = new JSONObject();
        body.put("trackName", track.name);
        body.put("trackLength", track.length);
        body.put("cornerCount", track.cornerCount);
        JSONArray points = new JSONArray();
        for (TrackPoint p : track.points) {
            points.put(new JSONObject().put("latitude", p.latitude).put("longitude", p.longitude).put("speed", p.speed).put("color", p.color));
        }
        body.put("points", points);
        return body;
    }

    private void handleLapTelemetry(Location location) {
        if (!isOnlineLoggedIn() || selectedTrack < 0 || selectedTrack >= tracks.size()) return;
        TrackData track = tracks.get(selectedTrack);
        if (track.remoteId == null || track.remoteId.isEmpty() || track.points.isEmpty()) return;
        if (!track.remoteId.equals(lapTrackRemoteId)) {
            lapTrackRemoteId = track.remoteId;
            lapStartedAt = 0;
            lastLapSampleAt = 0;
            wasNearStart = false;
            lapSamples.clear();
        }
        long now = System.currentTimeMillis();
        if (now - lastLapSampleAt > 400) {
            lastLapSampleAt = now;
            double speedKph = location.hasSpeed() ? Math.max(location.getSpeed(), 0) * 3.6 : 0;
            double deviation = lineDeviationMeters(location, track);
            lapSamples.add(new TelemetrySample(location.getLatitude(), location.getLongitude(), speedKph, "green", latestAccelerationY, latestAccelerationY, latestAccelerationX, deviation));
            while (lapSamples.size() > 700) lapSamples.remove(0);
        }
        TrackPoint current = new TrackPoint(location.getLatitude(), location.getLongitude(), 0, "green");
        boolean nearStart = distanceMeters(current, track.points.get(0)) < 8;
        if (nearStart && !wasNearStart) {
            if (lapStartedAt > 0) {
                long lapTimeMs = now - lapStartedAt;
                if (lapTimeMs > 15000 && lapSamples.size() >= 20) {
                    ArrayList<TelemetrySample> samples = new ArrayList<>(lapSamples);
                    uploadLap(track.remoteId, lapTimeMs, location, samples);
                }
            }
            lapStartedAt = now;
            lapSamples.clear();
            lastLapSampleAt = 0;
        }
        wasNearStart = nearStart;
    }

    private void uploadLap(String remoteId, long lapTimeMs, Location location, ArrayList<TelemetrySample> samples) {
        new Thread(() -> {
            try {
                JSONObject body = new JSONObject();
                body.put("lapTimeMs", lapTimeMs);
                body.put("speedKph", location.hasSpeed() ? Math.max(location.getSpeed(), 0) * 3.6 : 0);
                body.put("gpsAccuracy", location.hasAccuracy() ? location.getAccuracy() : 0);
                JSONArray arr = new JSONArray();
                for (TelemetrySample p : samples) arr.put(p.toJson());
                body.put("samples", arr);
                JSONObject response = onlineApi("/api/tracks/" + URLEncoder.encode(remoteId, "UTF-8") + "/laps", "POST", body, true);
                String summary = lapAnalysisMessage(lapTimeMs, response.optJSONObject("analysis"));
                runOnUiThread(() -> toast(summary));
            } catch (Exception e) { runOnUiThread(() -> toast("圈速上传失败：" + e.getMessage())); }
        }).start();
    }

    private String lapAnalysisMessage(long lapTimeMs, JSONObject analysis) {
        if (analysis == null) return "圈速已上传：" + formatLapTime((int) lapTimeMs);
        JSONArray suggestions = analysis.optJSONArray("suggestions");
        String suggestion = suggestions != null && suggestions.length() > 0 ? suggestions.optString(0) : "暂无建议";
        return "圈速已上传：" + formatLapTime((int) lapTimeMs)
                + "\n油门 " + analysis.optInt("throttleScore") + "% · 刹车 " + analysis.optInt("brakeScore") + "%"
                + " · 偏离 " + String.format(Locale.US, "%.1fm", analysis.optDouble("lineDeviationAvg"))
                + "\n" + suggestion;
    }

    private String formatLapTime(int milliseconds) {
        int minutes = milliseconds / 60000;
        int seconds = (milliseconds % 60000) / 1000;
        int millis = milliseconds % 1000;
        return String.format(Locale.US, "%d:%02d.%03d", minutes, seconds, millis);
    }

    private void showTrackList() {
        LinearLayout box = glassDialogBox();
        LinearLayout tools = new LinearLayout(this);
        tools.setGravity(Gravity.CENTER);
        addButton(tools, "图片描线", v -> { closeOpenDialogs(); showAITrackGenerator(); });
        addButton(tools, "地图绘制", v -> { closeOpenDialogs(); showMapDrawer(); });
        box.addView(tools, new LinearLayout.LayoutParams(-1, dp(62)));
        ScrollView scroll = new ScrollView(this);
        LinearLayout rows = new LinearLayout(this);
        rows.setOrientation(LinearLayout.VERTICAL);
        if (tracks.isEmpty()) rows.addView(label("暂无赛道"));
        for (int i = 0; i < tracks.size(); i++) rows.addView(trackRow(i));
        scroll.addView(rows);
        box.addView(scroll, new LinearLayout.LayoutParams(-1, dp(360)));
        animateChildrenStaggered(rows);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("已导入赛道").setView(box).setPositiveButton("完成", null).create());
    }

    private void closeOpenDialogs() {
        if (activeDialog != null) activeDialog.dismiss();
        activeDialog = null;
    }

    private View trackRow(int index) {
        TrackData track = tracks.get(index);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(12), dp(8), dp(12), dp(8));
        row.setBackground(mnsjGlowBackground(selectedTrack == index ? "#242424" : "#1C1C1C", 24, 1, selectedTrack == index ? "#9C5F54" : "#333333"));
        row.setOnTouchListener((view, event) -> {
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
                view.animate().scaleX(0.985f).scaleY(0.985f).alpha(0.92f).setDuration(90).start();
            } else if (event.getAction() == MotionEvent.ACTION_UP || event.getAction() == MotionEvent.ACTION_CANCEL) {
                view.animate().scaleX(1f).scaleY(1f).alpha(1f).setDuration(180).setInterpolator(new OvershootInterpolator(1.2f)).start();
            }
            return false;
        });
        LinearLayout texts = new LinearLayout(this);
        texts.setOrientation(LinearLayout.VERTICAL);
        TextView name = label(track.name);
        name.setTypeface(Typeface.DEFAULT_BOLD);
        TextView meta = label((int) track.length + "m · " + track.cornerCount + "弯 · " + track.points.size() + "点");
        meta.setTextSize(13);
        meta.setTextColor(Color.argb(170, 255, 255, 255));
        texts.addView(name);
        texts.addView(meta);
        row.addView(texts, new LinearLayout.LayoutParams(0, -2, 1));
        Button select = addButton(row, "选择", v -> { selectTrack(index); showMapCalibration(index); });
        Button rename = addButton(row, "重命名", v -> renameTrack(index));
        Button delete = addButton(row, "删除", v -> { deleteTrack(index); closeOpenDialogs(); showTrackList(); });
        select.setMinWidth(dp(86));
        rename.setMinWidth(dp(96));
        delete.setMinWidth(dp(86));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.setMargins(0, dp(6), 0, dp(6));
        row.setLayoutParams(lp);
        return row;
    }

    private void renameSelected() { if (selectedTrack >= 0) renameTrack(selectedTrack); }
    private void renameTrack(int index) { if (index < 0 || index >= tracks.size()) return; EditText input = new EditText(this); input.setText(tracks.get(index).name); input.setTextColor(Color.WHITE); input.setHintTextColor(0xAAFFFFFF); input.setBackground(mnsjControlBackground()); showGlassDialog(new AlertDialog.Builder(this).setTitle("重命名赛道").setView(input).setPositiveButton("保存", (d, w) -> { tracks.get(index).name = input.getText().toString().trim(); saveTracks(); selectTrack(index); }).setNegativeButton("取消", null).create()); }
    private void deleteSelected() { if (selectedTrack >= 0) deleteTrack(selectedTrack); }
    private void deleteTrack(int index) { if (index < 0 || index >= tracks.size()) return; tracks.remove(index); selectedTrack = tracks.isEmpty() ? -1 : Math.min(index, tracks.size() - 1); saveTracks(); if (selectedTrack >= 0) selectTrack(selectedTrack); else if (overlay != null) overlay.setTrack(new ArrayList<>()); updateHud(); toast("已删除"); }

    private void showMapCalibration(int index) {
        if (index < 0 || index >= tracks.size()) return;
        LinearLayout box = glassDialogBox();
        TextView help = label("在地图上点击你当前所在位置；拖动红色方向箭头或使用滑块校准车头方向。");
        help.setTextColor(Color.argb(190, 255, 255, 255));
        box.addView(help);
        CalibrationCanvas canvas = new CalibrationCanvas(this, tracks.get(index));
        box.addView(canvas, new LinearLayout.LayoutParams(-1, dp(340)));
        TextView direction = label("方向 0°");
        box.addView(direction);
        SeekBar heading = new SeekBar(this);
        heading.setMax(359);
        heading.setBackground(mnsjControlBackground());
        heading.setPadding(dp(10), dp(6), dp(10), dp(6));
        heading.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) { canvas.headingDegrees = progress; direction.setText("方向 " + progress + "°"); canvas.invalidate(); }
            public void onStartTrackingTouch(SeekBar seekBar) {}
            public void onStopTrackingTouch(SeekBar seekBar) {}
        });
        box.addView(heading, new LinearLayout.LayoutParams(-1, dp(48)));
        TextView point = label("当前位置点：#1 / " + tracks.get(index).points.size());
        box.addView(point);
        animateChildrenStaggered(box);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("校准地图").setView(box).setPositiveButton("加载赛道并应用校准", (d, w) -> { selectTrack(index); toast("已按地图选择校准位置和方向"); }).setNegativeButton("取消", null).create());
    }

    private void showSettings() {
        LinearLayout box = glassDialogBox();
        box.addView(sectionLabel("行车线样式"));
        SeekBar opacity = addSlider(box, "透明度", 15, 100, (int) Math.round(lineOpacity * 100));
        SeekBar width = addSlider(box, "宽度", 20, 120, (int) Math.round(lineWidth * 100));
        SeekBar height = addSlider(box, "离地高度", 0, 35, (int) Math.round(lineHeight));
        SeekBar distance = addSlider(box, "前方显示距离", 30, 200, (int) renderDistance);
        SeekBar bright = addSlider(box, "亮度", 20, 100, (int) Math.round(lineBrightness * 100));
        CheckBox depth = addCheckBox(box, "禁用深度测试（提升帧率）", disableDepthTest);
        box.addView(sectionLabel("传感器与性能"));
        RadioGroup gps = radioGroup(new String[]{"导航级", "最佳", "10米"}, gpsAccuracyIndex);
        box.addView(label("GPS精度"));
        box.addView(gps);
        RadioGroup resolution = radioGroup(new String[]{"720p（低发热）", "1080p（更清晰）"}, lowHeatMode ? 0 : 1);
        box.addView(label("相机分辨率"));
        box.addView(resolution);
        CheckBox power = addCheckBox(box, "省电模式（AR 30fps）", powerSavingMode);
        box.addView(sectionLabel("单位"));
        CheckBox metric = addCheckBox(box, "公制单位", metricUnits);
        box.addView(sectionLabel("安全"));
        TextView safety = label("请只在封闭赛道使用。手机必须固定牢靠，AR提示不能替代驾驶判断。");
        safety.setTextColor(Color.argb(180, 255, 255, 255));
        box.addView(safety);
        animateChildrenStaggered(box);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("设置").setView(box).setPositiveButton("完成", (d, w) -> {
            lineOpacity = (15 + opacity.getProgress()) / 100.0;
            lineWidth = (20 + width.getProgress()) / 100.0;
            lineHeight = height.getProgress();
            renderDistance = 30 + distance.getProgress();
            lineBrightness = (20 + bright.getProgress()) / 100.0;
            disableDepthTest = depth.isChecked();
            gpsAccuracyIndex = Math.max(0, gps.indexOfChild(gps.findViewById(gps.getCheckedRadioButtonId())));
            lowHeatMode = resolution.indexOfChild(resolution.findViewById(resolution.getCheckedRadioButtonId())) == 0;
            powerSavingMode = power.isChecked();
            metricUnits = metric.isChecked();
            overlay.setRenderDistance(renderDistance);
            overlay.setVerticalOffset(lineHeight);
            overlay.setLineStyle(lineOpacity, lineWidth, lineBrightness);
            prefs.edit()
                    .putLong("renderDistance", Double.doubleToRawLongBits(renderDistance))
                    .putLong("lineOpacity", Double.doubleToRawLongBits(lineOpacity))
                    .putLong("lineWidth", Double.doubleToRawLongBits(lineWidth))
                    .putLong("lineBrightness", Double.doubleToRawLongBits(lineBrightness))
                    .putFloat("lineHeight", lineHeight)
                    .putBoolean("lowHeat", lowHeatMode)
                    .putBoolean("powerSaving", powerSavingMode)
                    .putBoolean("disableDepthTest", disableDepthTest)
                    .putBoolean("metricUnits", metricUnits)
                    .putInt("gpsAccuracy", gpsAccuracyIndex)
                    .apply();
            startLocationUpdatesIfAllowed();
            restartCamera();
            updateHud();
        }).create());
    }
    private TextView label(String s) { TextView v = new TextView(this); v.setText(s); v.setTextSize(16); v.setTextColor(Color.WHITE); v.setPadding(0, dp(10), 0, dp(4)); return v; }

    private TextView sectionLabel(String s) { TextView v = label(s); v.setTypeface(Typeface.DEFAULT_BOLD); v.setTextSize(18); return v; }

    private SeekBar addSlider(LinearLayout box, String title, int min, int max, int value) {
        box.addView(label(title));
        SeekBar bar = new SeekBar(this);
        bar.setMax(max - min);
        bar.setProgress(Math.max(0, Math.min(max - min, value - min)));
        bar.setPadding(dp(10), dp(6), dp(10), dp(6));
        bar.setBackground(mnsjControlBackground());
        box.addView(bar, new LinearLayout.LayoutParams(-1, dp(46)));
        return bar;
    }

    private CheckBox addCheckBox(LinearLayout box, String text, boolean checked) {
        CheckBox check = new AnimatedSwitchCheckBox(this);
        check.setText(text);
        check.setTextColor(Color.WHITE);
        check.setTextSize(16);
        check.setChecked(checked);
        check.setBackground(mnsjControlBackground());
        check.setPadding(dp(14), dp(6), dp(78), dp(6));
        box.addView(check, new LinearLayout.LayoutParams(-1, dp(54)));
        return check;
    }

    private RadioGroup radioGroup(String[] labels, int checkedIndex) {
        RadioGroup group = new RadioGroup(this);
        group.setOrientation(RadioGroup.HORIZONTAL);
        group.setBackground(mnsjControlBackground());
        group.setPadding(dp(8), dp(4), dp(8), dp(4));
        group.setLayoutTransition(mnsjLayoutTransition());
        for (int i = 0; i < labels.length; i++) {
            RadioButton item = new RadioButton(this);
            item.setText(labels[i]);
            item.setTextColor(Color.WHITE);
            item.setTextSize(15);
            item.setId(View.generateViewId());
            item.setButtonDrawable(null);
            item.setGravity(Gravity.CENTER);
            item.setBackground(mnsjButtonBackground(false));
            item.setOnTouchListener((view, event) -> {
                if (event.getAction() == MotionEvent.ACTION_DOWN) view.animate().scaleX(0.96f).scaleY(0.96f).setDuration(80).start();
                else if (event.getAction() == MotionEvent.ACTION_UP || event.getAction() == MotionEvent.ACTION_CANCEL) view.animate().scaleX(1f).scaleY(1f).setDuration(170).setInterpolator(new OvershootInterpolator(1.25f)).start();
                return false;
            });
            RadioGroup.LayoutParams itemParams = new RadioGroup.LayoutParams(0, dp(46));
            itemParams.weight = 1;
            group.addView(item, itemParams);
            if (i == checkedIndex) group.check(item.getId());
        }
        return group;
    }

    private void showAISettings() {
        LinearLayout box = glassDialogBox();
        EditText key = new EditText(this); key.setHint("AI API Key"); key.setText(prefs.getString("apiKey", ""));
        EditText base = new EditText(this); base.setHint("Base URL"); base.setText(prefs.getString("baseUrl", "https://api.tutujin.com/v1"));
        EditText model = new EditText(this); model.setHint("Model"); model.setText(prefs.getString("model", "claude-3-5-sonnet-20240620"));
        box.addView(key); box.addView(base); box.addView(model);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("AI设置").setView(box).setPositiveButton("保存", (d, w) -> prefs.edit().putString("apiKey", key.getText().toString()).putString("baseUrl", base.getText().toString()).putString("model", model.getText().toString()).apply()).create());
    }

    private void showAITrackGenerator() {
        isMainScreen = false;
        pauseCamera();
        selectedAIImage = null;
        selectedAIFinishPoint = null;
        aiDrawnPoints.clear();
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(14), dp(14), dp(14), dp(14));
        root.setBackgroundColor(Color.BLACK);
        LinearLayout header = new LinearLayout(this);
        header.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = label("图片描线生成");
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextSize(22);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        addButton(header, "关闭", v -> backHome());
        root.addView(header, new LinearLayout.LayoutParams(-1, dp(62)));
        Button photo = new Button(this);
        photo.setText("选择赛道照片");
        applyGlassButton(photo);
        photo.setOnClickListener(v -> pickAIImage());
        root.addView(photo, new LinearLayout.LayoutParams(-1, dp(56)));
        EditText name = aiField("赛道名称", "图片描线赛道", false);
        EditText length = aiField("赛道长度米（不知道填800）", prefs.getString("imageTrackLength", "800"), false);
        length.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
        root.addView(name);
        root.addView(length);
        LinearLayout traceTools = new LinearLayout(this);
        traceTools.setGravity(Gravity.CENTER);
        addButton(traceTools, "撤销", v -> { if (!aiDrawnPoints.isEmpty()) { aiDrawnPoints.remove(aiDrawnPoints.size() - 1); updateAITraceMessage(); if (aiImageView != null) aiImageView.invalidate(); } });
        addButton(traceTools, "清空", v -> { aiDrawnPoints.clear(); updateAITraceMessage(); if (aiImageView != null) aiImageView.invalidate(); });
        root.addView(traceTools, new LinearLayout.LayoutParams(-1, dp(58)));
        aiImageView = new ImagePointView(this);
        LinearLayout.LayoutParams imageLp = new LinearLayout.LayoutParams(-1, 0, 1);
        imageLp.setMargins(0, dp(12), 0, dp(8));
        root.addView(aiImageView, imageLp);
        aiMessage = label("选择赛道俯视图，然后沿赛道中心线手指描一圈。");
        aiMessage.setTextColor(Color.argb(190, 255, 255, 255));
        root.addView(aiMessage);
        Button generate = new Button(this);
        generate.setText("按描线生成并导入");
        applyGlassButton(generate);
        generate.setOnClickListener(v -> {
            prefs.edit().putString("imageTrackLength", length.getText().toString()).apply();
            generateImageTraceTrack(name.getText().toString(), length.getText().toString());
        });
        root.addView(generate, new LinearLayout.LayoutParams(-1, dp(58)));
        setContentView(root);
        root.post(() -> {
            root.setAlpha(0f);
            root.setScaleX(0.96f);
            root.setScaleY(0.96f);
            root.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(320).setInterpolator(new DecelerateInterpolator(1.4f)).start();
            animateChildrenStaggered(root);
        });
    }

    private EditText aiField(String hint, String value, boolean secure) {
        EditText input = new EditText(this);
        input.setHint(hint);
        input.setText(value);
        input.setSingleLine(true);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(0xAAFFFFFF);
        input.setBackground(mnsjControlBackground());
        input.setPadding(dp(12), 0, dp(12), 0);
        if (secure) input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, dp(54));
        lp.setMargins(0, dp(6), 0, 0);
        input.setLayoutParams(lp);
        return input;
    }

    private void pickAIImage() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("image/*");
        startActivityForResult(intent, REQ_IMAGE);
    }

    private void loadAIImage(Uri uri) {
        try (InputStream in = getContentResolver().openInputStream(uri)) {
            selectedAIImage = BitmapFactory.decodeStream(in);
            selectedAIFinishPoint = null;
            aiDrawnPoints.clear();
            if (aiImageView != null) aiImageView.setImage(selectedAIImage);
            if (aiMessage != null) aiMessage.setText("照片已选择。沿赛道中心线描一圈，首尾会自动闭合。");
        } catch (Exception e) { toast("照片读取失败：" + e.getMessage()); }
    }

    private void generateImageTraceTrack(String name, String lengthText) {
        if (selectedAIImage == null || aiDrawnPoints.size() < 8) { toast("请先选择照片并沿赛道描一圈"); return; }
        try {
            double length = Double.parseDouble(lengthText.trim().isEmpty() ? "800" : lengthText.trim());
            if (Double.isNaN(length) || Double.isInfinite(length) || length < 120) length = 800;
            TrackData track = buildTrackFromImageTrace(name, length);
            addTrack(track);
            toast("已生成并导入：" + track.name);
            backHome();
        } catch (Exception e) {
            toast("描线生成失败：" + e.getMessage());
            if (aiMessage != null) aiMessage.setText("描线点太少或路径无效，请沿赛道中心线完整描一圈。");
        }
    }

    private void generateAITrack() {
        if (selectedAIImage == null || selectedAIFinishPoint == null) { toast("请先选择照片并点击起终点"); return; }
        if (prefs.getString("apiKey", "").trim().isEmpty()) { toast("请先输入AI接口Key"); return; }
        if (aiMessage != null) aiMessage.setText("AI正在分析赛道并生成约0.5米分段的平滑行车线，可能需要1-3分钟。");
        new Thread(() -> {
            try {
                TrackData track = callAIForImageTrack(selectedAIImage, selectedAIFinishPoint);
                runOnUiThread(() -> { addTrack(track); toast("已生成并导入：" + track.name); backHome(); });
            } catch (Exception e) {
                runOnUiThread(() -> { if (aiMessage != null) aiMessage.setText("生成失败，请检查Key、网络或图片质量。"); toast("AI生成失败：" + e.getMessage()); });
            }
        }).start();
    }

    private void showMapDrawer() { isMainScreen = false; pauseCamera(); setContentView(new MapDrawerView(this)); }
    private void backHome() { isMainScreen = true; buildMainUi(); if (selectedTrack >= 0) selectTrack(selectedTrack); requestCameraIfNeeded(); startLocationUpdatesIfAllowed(); }

    private void saveTracks() { try { JSONArray arr = new JSONArray(); for (TrackData t : tracks) { JSONObject o = new JSONObject(); if (t.remoteId != null && !t.remoteId.isEmpty()) o.put("remoteID", t.remoteId); o.put("trackName", t.name); o.put("trackLength", t.length); o.put("cornerCount", t.cornerCount); JSONArray pts = new JSONArray(); for (TrackPoint p : t.points) { JSONObject po = new JSONObject(); po.put("latitude", p.latitude); po.put("longitude", p.longitude); po.put("speed", p.speed); po.put("color", p.color); pts.put(po); } o.put("points", pts); arr.put(o); } prefs.edit().putString("tracks", arr.toString()).apply(); } catch (Exception ignored) {} }
    private void loadTracks() { try { String raw = prefs.getString("tracks", null); if (raw == null) return; JSONArray arr = new JSONArray(raw); for (int i = 0; i < arr.length(); i++) tracks.add(parseTrack(arr.getJSONObject(i).toString(), "本地赛道")); } catch (Exception ignored) {} }

    private void startCameraWhenReady() { if (!isMainScreen || cameraPreview == null) return; cameraPreview.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() { public void onSurfaceTextureAvailable(SurfaceTexture s, int w, int h) { openCamera(s); } public void onSurfaceTextureSizeChanged(SurfaceTexture s, int w, int h) {} public boolean onSurfaceTextureDestroyed(SurfaceTexture s) { pauseCamera(); return true; } public void onSurfaceTextureUpdated(SurfaceTexture s) {} }); if (cameraPreview.isAvailable()) openCamera(cameraPreview.getSurfaceTexture()); }
    private void restartCamera() { pauseCamera(); startCameraWhenReady(); }
    private void openCamera(SurfaceTexture st) { if (!isMainScreen) return; try { CameraManager m = (CameraManager) getSystemService(CAMERA_SERVICE); String id = findBackCamera(m); if (id == null) { showNoCameraBackground("无相机：模拟器预览模式"); return; } st.setDefaultBufferSize(lowHeatMode ? 1280 : 1920, lowHeatMode ? 720 : 1080); if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return; m.openCamera(id, new CameraDevice.StateCallback() { public void onOpened(CameraDevice c) { cameraDevice = c; startPreview(st); } public void onDisconnected(CameraDevice c) { c.close(); } public void onError(CameraDevice c, int e) { c.close(); showNoCameraBackground("相机错误：" + e); } }, null); } catch (Exception e) { showNoCameraBackground("无可用相机：" + e.getMessage()); } }
    private String findBackCamera(CameraManager m) throws CameraAccessException { for (String id : m.getCameraIdList()) { Integer f = m.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING); if (f != null && f == CameraCharacteristics.LENS_FACING_BACK) return id; } return m.getCameraIdList().length > 0 ? m.getCameraIdList()[0] : null; }
    private void startPreview(SurfaceTexture t) { try { Surface s = new Surface(t); CaptureRequest.Builder b = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW); b.addTarget(s); cameraDevice.createCaptureSession(Collections.singletonList(s), new CameraCaptureSession.StateCallback() { public void onConfigured(CameraCaptureSession session) { cameraSession = session; try { session.setRepeatingRequest(b.build(), null, null); } catch (Exception e) { showNoCameraBackground("预览失败"); } } public void onConfigureFailed(CameraCaptureSession session) { showNoCameraBackground("预览配置失败"); } }, null); } catch (Exception e) { showNoCameraBackground("预览失败：" + e.getMessage()); } }
    @Override protected void onDestroy() { super.onDestroy(); stopScreenRecordingIfNeeded(); pauseCamera(); stopAccelerationUpdates(); if (locationService != null && locationListener != null) locationService.removeUpdates(locationListener); }

    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_LONG).show(); }
    private double computeLength(List<TrackPoint> pts) { double d = 0; for (int i = 1; i < pts.size(); i++) d += distanceMeters(pts.get(i - 1), pts.get(i)); return d; }
    private double distanceMeters(TrackPoint a, TrackPoint b) { double dLat = Math.toRadians(b.latitude - a.latitude), dLon = Math.toRadians(b.longitude - a.longitude), lat1 = Math.toRadians(a.latitude), lat2 = Math.toRadians(b.latitude); double h = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) * Math.sin(dLon / 2); return 6371000.0 * 2.0 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h)); }
    private double lineDeviationMeters(Location location, TrackData track) { return lineDeviationMeters(new TrackPoint(location.getLatitude(), location.getLongitude(), 0, "green"), track.points); }
    private double lineDeviationMeters(TrackPoint point, List<TrackPoint> points) { if (points.size() < 2) return 0; double best = Double.MAX_VALUE; for (int i = 1; i < points.size(); i++) best = Math.min(best, distanceToSegmentMeters(point, points.get(i - 1), points.get(i))); return best == Double.MAX_VALUE ? 0 : Math.min(best, 80); }
    private double distanceToSegmentMeters(TrackPoint point, TrackPoint start, TrackPoint end) { double latScale = Math.PI / 180.0 * 6371000.0; double lonScale = latScale * Math.cos(Math.toRadians(point.latitude)); double ax = (start.longitude - point.longitude) * lonScale, ay = (start.latitude - point.latitude) * latScale, bx = (end.longitude - point.longitude) * lonScale, by = (end.latitude - point.latitude) * latScale; double dx = bx - ax, dy = by - ay, lengthSquared = dx * dx + dy * dy; if (lengthSquared <= 0.000001) return distanceMeters(point, start); double t = Math.max(0, Math.min(1, -(ax * dx + ay * dy) / lengthSquared)); double nx = ax + dx * t, ny = ay + dy * t; return Math.sqrt(nx * nx + ny * ny); }

    final class MapDrawerView extends LinearLayout {
        DrawCanvas canvas;
        EditText search;
        EditText trackName;
        TextView message;

        MapDrawerView(Context context) {
            super(context);
            setOrientation(VERTICAL);
            setPadding(dp(12), dp(12), dp(12), dp(12));
            setBackgroundColor(Color.BLACK);
            LinearLayout top = new LinearLayout(context);
            top.setGravity(Gravity.CENTER_VERTICAL);
            search = new EditText(context);
            search.setHint("搜索卡丁车场/地点");
            search.setSingleLine(true);
            search.setTextColor(Color.WHITE);
            search.setHintTextColor(0xAAFFFFFF);
            search.setBackground(mnsjControlBackground());
            search.setPadding(dp(12), 0, dp(12), 0);
            Button find = addButton(top, "搜索", v -> searchPlace());
            top.addView(search, 0, new LinearLayout.LayoutParams(0, dp(52), 1));
            addView(top, new LinearLayout.LayoutParams(-1, dp(62)));
            LinearLayout mode = new LinearLayout(context);
            Button move = addButton(mode, "移动缩放", v -> { canvas.drawMode = false; canvas.invalidate(); });
            Button draw = addButton(mode, "绘制", v -> { canvas.drawMode = true; canvas.invalidate(); });
            addView(mode, new LinearLayout.LayoutParams(-1, dp(62)));
            canvas = new DrawCanvas(context);
            LinearLayout.LayoutParams canvasLp = new LinearLayout.LayoutParams(-1, 0, 1);
            canvasLp.setMargins(0, dp(8), 0, dp(8));
            addView(canvas, canvasLp);
            trackName = aiField("赛道名称", "地图绘制赛道", false);
            addView(trackName);
            message = label("模式1可移动缩放地图；切到绘制模式后在实景地图上描出赛道。");
            message.setTextColor(Color.argb(190, 255, 255, 255));
            addView(message);
            LinearLayout actions = new LinearLayout(context);
            addButton(actions, "撤销", v -> canvas.undo());
            addButton(actions, "清空", v -> canvas.clear());
            addButton(actions, "首尾相接", v -> canvas.closeLoop());
            addButton(actions, "关闭", v -> backHome());
            addView(actions, new LinearLayout.LayoutParams(-1, dp(62)));
            Button ai = new Button(context);
            ai.setText("发送地图轨迹给AI生成刹车区");
            applyGlassButton(ai);
            ai.setOnClickListener(v -> generateFromDrawing());
            addView(ai, new LinearLayout.LayoutParams(-1, dp(58)));
            post(() -> {
                setAlpha(0f);
                setScaleX(0.96f);
                setScaleY(0.96f);
                animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(320).setInterpolator(new DecelerateInterpolator(1.4f)).start();
                animateChildrenStaggered(this);
            });
        }

        void searchPlace() { try { List<Address> list = new Geocoder(MainActivity.this).getFromLocationName(search.getText().toString(), 1); if (list != null && !list.isEmpty()) { canvas.centerLat = list.get(0).getLatitude(); canvas.centerLon = list.get(0).getLongitude(); message.setText("已定位到：" + (list.get(0).getFeatureName() == null ? search.getText().toString() : list.get(0).getFeatureName()) + "。切到绘制模式后描出赛道。"); } } catch (Exception e) { toast("搜索失败：" + e.getMessage()); } }
        void generateFromDrawing() { if (!canvas.closed()) { toast("赛道必须首尾相接后才能生成"); return; } message.setText("AI正在根据地图轨迹生成速度和刹车区。"); ArrayList<TrackPoint> pts = canvas.toTrackPoints(); new Thread(() -> { try { TrackData t = callAIForBrakeZones(pts); runOnUiThread(() -> { addTrack(t); backHome(); }); } catch (Exception e) { TrackData t = new TrackData(); t.name = trackName.getText().toString().trim().isEmpty() ? "地图绘制赛道" : trackName.getText().toString().trim(); t.points.addAll(pts); t.length = computeLength(pts); markLocalBrakeZones(t.points); runOnUiThread(() -> { addTrack(t); toast("AI失败，已生成本地刹车区"); backHome(); }); } }).start(); }
    }

    final class DrawCanvas extends View {
        final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        final ArrayList<PointF> drawn = new ArrayList<>();
        double centerLat = 31.2304, centerLon = 121.4737;
        boolean drawMode = false;

        DrawCanvas(Context context) { super(context); p.setStrokeWidth(dp(5)); p.setStrokeCap(Paint.Cap.ROUND); p.setStrokeJoin(Paint.Join.ROUND); }
        protected void onDraw(Canvas canvas) { canvas.drawColor(Color.rgb(8, 8, 8)); p.setStyle(Paint.Style.FILL); p.setTextSize(dp(18)); p.setColor(Color.WHITE); canvas.drawText(drawMode ? "绘制赛道线" : "移动缩放地图", dp(18), dp(32), p); canvas.drawText("点数：" + drawn.size() + " · 长度：" + (int) computeLength(toTrackPoints()) + "m · " + (closed() ? "已首尾相接" : "未闭合"), dp(18), dp(58), p); p.setStyle(Paint.Style.STROKE); p.setStrokeWidth(dp(5)); p.setColor(Color.rgb(0, 255, 70)); for (int i = 1; i < drawn.size(); i++) canvas.drawLine(drawn.get(i - 1).x, drawn.get(i - 1).y, drawn.get(i).x, drawn.get(i).y, p); }
        public boolean onTouchEvent(android.view.MotionEvent event) { if (!drawMode) return true; if (event.getAction() == android.view.MotionEvent.ACTION_DOWN || event.getAction() == android.view.MotionEvent.ACTION_MOVE) { PointF pt = new PointF(event.getX(), event.getY()); if (drawn.isEmpty() || dist(drawn.get(drawn.size() - 1), pt) > dp(2)) { drawn.add(pt); invalidate(); } return true; } return true; }
        void undo() { if (!drawn.isEmpty()) { drawn.remove(drawn.size() - 1); invalidate(); } }
        void clear() { drawn.clear(); invalidate(); }
        void closeLoop() { if (drawn.size() > 2) { drawn.add(new PointF(drawn.get(0).x, drawn.get(0).y)); invalidate(); } }
        boolean closed() { return drawn.size() > 3 && dist(drawn.get(0), drawn.get(drawn.size() - 1)) < dp(20); }
        float dist(PointF a, PointF b) { return (float) Math.hypot(a.x - b.x, a.y - b.y); }
        ArrayList<TrackPoint> toTrackPoints() { ArrayList<TrackPoint> out = new ArrayList<>(); double mpp = 0.5, latScale = 111320.0, lonScale = Math.max(Math.cos(Math.toRadians(centerLat)) * 111320.0, 1); for (PointF pt : drawn) { double east = (pt.x - getWidth() / 2.0) * mpp; double north = (getHeight() / 2.0 - pt.y) * mpp; out.add(new TrackPoint(centerLat + north / latScale, centerLon + east / lonScale, 60, "green")); } return out; }
    }

    final class ImagePointView extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        Bitmap bitmap;
        RectF imageRect = new RectF();

        ImagePointView(Context context) { super(context); setBackgroundColor(Color.BLACK); }
        void setImage(Bitmap image) { bitmap = image; invalidate(); }

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.BLACK);
            canvas.drawRoundRect(new RectF(0, 0, getWidth(), getHeight()), dp(16), dp(16), paint);
            if (bitmap == null) {
                paint.setColor(Color.argb(170, 255, 255, 255));
                paint.setTextSize(dp(22));
                paint.setTextAlign(Paint.Align.CENTER);
                canvas.drawText("请选择一张赛道俯视图", getWidth() / 2f, getHeight() / 2f, paint);
                return;
            }
            fitImageRect();
            canvas.drawBitmap(bitmap, null, imageRect, null);
            if (!aiDrawnPoints.isEmpty()) {
                Path path = new Path();
                PointF first = imageToView(aiDrawnPoints.get(0));
                path.moveTo(first.x, first.y);
                for (int i = 1; i < aiDrawnPoints.size(); i++) {
                    PointF point = imageToView(aiDrawnPoints.get(i));
                    path.lineTo(point.x, point.y);
                }
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(dp(5));
                paint.setStrokeCap(Paint.Cap.ROUND);
                paint.setStrokeJoin(Paint.Join.ROUND);
                paint.setColor(Color.rgb(0, 255, 70));
                canvas.drawPath(path, paint);
                if (aiDrawnPoints.size() > 2) {
                    PointF last = imageToView(aiDrawnPoints.get(aiDrawnPoints.size() - 1));
                    paint.setStrokeWidth(dp(2));
                    paint.setColor(Color.argb(150, 255, 255, 255));
                    canvas.drawLine(last.x, last.y, first.x, first.y, paint);
                }
                paint.setStyle(Paint.Style.FILL);
                for (int i = 0; i < aiDrawnPoints.size(); i++) {
                    PointF point = imageToView(aiDrawnPoints.get(i));
                    paint.setColor(i == 0 ? Color.RED : Color.rgb(0, 255, 70));
                    canvas.drawCircle(point.x, point.y, i == 0 ? dp(7) : dp(4), paint);
                }
            }
        }

        @Override public boolean onTouchEvent(android.view.MotionEvent event) {
            if (bitmap == null) return true;
            if (event.getAction() == android.view.MotionEvent.ACTION_DOWN || event.getAction() == android.view.MotionEvent.ACTION_MOVE || event.getAction() == android.view.MotionEvent.ACTION_UP) {
                fitImageRect();
                if (!imageRect.contains(event.getX(), event.getY())) return true;
                PointF imagePoint = new PointF((event.getX() - imageRect.left) / imageRect.width() * bitmap.getWidth(), (event.getY() - imageRect.top) / imageRect.height() * bitmap.getHeight());
                if (aiDrawnPoints.isEmpty() || Math.hypot(imagePoint.x - aiDrawnPoints.get(aiDrawnPoints.size() - 1).x, imagePoint.y - aiDrawnPoints.get(aiDrawnPoints.size() - 1).y) >= 6) {
                    aiDrawnPoints.add(imagePoint);
                    updateAITraceMessage();
                }
                invalidate();
                return true;
            }
            return true;
        }

        private PointF imageToView(PointF point) {
            return new PointF(imageRect.left + point.x / bitmap.getWidth() * imageRect.width(), imageRect.top + point.y / bitmap.getHeight() * imageRect.height());
        }

        private void fitImageRect() {
            if (bitmap == null || getWidth() <= 0 || getHeight() <= 0) { imageRect.setEmpty(); return; }
            float scale = Math.min(getWidth() / (float) bitmap.getWidth(), getHeight() / (float) bitmap.getHeight());
            float width = bitmap.getWidth() * scale;
            float height = bitmap.getHeight() * scale;
            imageRect.set((getWidth() - width) / 2f, (getHeight() - height) / 2f, (getWidth() + width) / 2f, (getHeight() + height) / 2f);
        }
    }

    private void updateAITraceMessage() {
        if (aiMessage == null) return;
        aiMessage.setText(aiDrawnPoints.isEmpty() ? "沿赛道中心线描一圈。" : "已记录 " + aiDrawnPoints.size() + " 个描线点。越贴近中心线，生成越准。");
    }

    private TrackData buildTrackFromImageTrace(String name, double targetLength) throws Exception {
        ArrayList<PointF> clean = new ArrayList<>();
        for (PointF point : aiDrawnPoints) {
            if (!clean.isEmpty() && Math.hypot(point.x - clean.get(clean.size() - 1).x, point.y - clean.get(clean.size() - 1).y) < 4) continue;
            clean.add(new PointF(point.x, point.y));
        }
        if (clean.size() < 4) throw new IOException("描线点太少");
        PointF first = clean.get(0);
        PointF last = clean.get(clean.size() - 1);
        if (Math.hypot(first.x - last.x, first.y - last.y) > 4) clean.add(new PointF(first.x, first.y));
        double pixelLength = imagePolylineLength(clean);
        double length = Math.max(targetLength, 120);
        int sampleCount = Math.min(Math.max((int) (length / 3.0), 120), 500);
        ArrayList<PointF> sampled = new ArrayList<>();
        for (int i = 0; i <= sampleCount; i++) sampled.add(imagePointOnPolyline(clean, pixelLength * i / sampleCount));
        ArrayList<String> colors = localImageTraceColors(sampled);
        double metersPerPixel = pixelLength > 1 ? length / pixelLength : 1;
        PointF anchor = sampled.get(0);
        double originLat = latestLocation != null ? latestLocation.getLatitude() : 31.234567;
        double originLon = latestLocation != null ? latestLocation.getLongitude() : 121.345678;
        double latScale = 111320.0;
        double lonScale = Math.max(Math.cos(Math.toRadians(originLat)) * 111320.0, 1);
        TrackData track = new TrackData();
        track.name = name.trim().isEmpty() ? "图片描线赛道" : name.trim();
        track.length = length;
        int redCount = 0;
        for (int i = 0; i < sampled.size(); i++) {
            PointF point = sampled.get(i);
            String color = colors.get(i);
            if ("red".equals(color)) redCount++;
            double east = (point.x - anchor.x) * metersPerPixel;
            double north = -(point.y - anchor.y) * metersPerPixel;
            track.points.add(new TrackPoint(originLat + north / latScale, originLon + east / lonScale, speedForColor(color), color));
        }
        track.cornerCount = Math.max(1, redCount / 6);
        return track;
    }

    private double imagePolylineLength(List<PointF> points) {
        double total = 0;
        for (int i = 1; i < points.size(); i++) total += Math.hypot(points.get(i).x - points.get(i - 1).x, points.get(i).y - points.get(i - 1).y);
        return total;
    }

    private PointF imagePointOnPolyline(List<PointF> points, double distance) {
        double travelled = 0;
        for (int i = 1; i < points.size(); i++) {
            PointF start = points.get(i - 1);
            PointF end = points.get(i);
            double segment = Math.hypot(end.x - start.x, end.y - start.y);
            if (travelled + segment >= distance) {
                float ratio = segment > 0 ? (float) ((distance - travelled) / segment) : 0f;
                return new PointF(start.x + (end.x - start.x) * ratio, start.y + (end.y - start.y) * ratio);
            }
            travelled += segment;
        }
        PointF last = points.get(points.size() - 1);
        return new PointF(last.x, last.y);
    }

    private ArrayList<String> localImageTraceColors(List<PointF> sampled) {
        int baseCount = Math.max(sampled.size() - 1, 1);
        double[] turns = new double[sampled.size()];
        for (int i = 0; i < sampled.size(); i++) {
            PointF previous = sampled.get((i - 4 + baseCount) % baseCount);
            PointF current = sampled.get(i % baseCount);
            PointF next = sampled.get((i + 4) % baseCount);
            double angleA = Math.atan2(current.y - previous.y, current.x - previous.x);
            double angleB = Math.atan2(next.y - current.y, next.x - current.x);
            double delta = Math.abs(Math.toDegrees(angleB - angleA)) % 360;
            turns[i] = delta > 180 ? 360 - delta : delta;
        }
        ArrayList<String> colors = new ArrayList<>();
        for (int i = 0; i < sampled.size(); i++) {
            double upcoming = 0;
            for (int j = 1; j <= 8; j++) upcoming = Math.max(upcoming, turns[(i + j) % baseCount]);
            double current = turns[i];
            if (upcoming > 34 || current > 38) colors.add("red");
            else if (upcoming > 18 || current > 20) colors.add("orange");
            else colors.add("green");
        }
        return colors;
    }

    private double speedForColor(String color) {
        if ("red".equals(color)) return 34;
        if ("orange".equals(color)) return 48;
        return 65;
    }

    final class CalibrationCanvas extends View {
        final TrackData track;
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        int selectedIndex = 0;
        int headingDegrees = 0;

        CalibrationCanvas(Context context, TrackData track) {
            super(context);
            this.track = track;
            setBackgroundColor(Color.BLACK);
        }

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            if (track.points.size() < 2) return;
            ArrayList<PointF> points = projectedPoints();
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(dp(3));
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setColor(Color.argb(190, 255, 255, 255));
            for (int i = 1; i < points.size(); i++) canvas.drawLine(points.get(i - 1).x, points.get(i - 1).y, points.get(i).x, points.get(i).y, paint);
            paint.setStyle(Paint.Style.FILL);
            for (int i = 0; i < points.size(); i++) {
                paint.setColor(colorForTrack(track.points.get(i).color, 1f));
                canvas.drawCircle(points.get(i).x, points.get(i).y, dp(3), paint);
            }
            PointF selected = points.get(Math.min(selectedIndex, points.size() - 1));
            paint.setColor(Color.RED);
            canvas.drawCircle(selected.x, selected.y, dp(9), paint);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(dp(5));
            float radians = (float) Math.toRadians(headingDegrees);
            canvas.drawLine(selected.x, selected.y, selected.x + (float) Math.cos(radians) * dp(54), selected.y - (float) Math.sin(radians) * dp(54), paint);
        }

        @Override public boolean onTouchEvent(android.view.MotionEvent event) {
            if (event.getAction() == android.view.MotionEvent.ACTION_DOWN || event.getAction() == android.view.MotionEvent.ACTION_UP) {
                ArrayList<PointF> points = projectedPoints();
                float best = Float.MAX_VALUE;
                for (int i = 0; i < points.size(); i++) {
                    float distance = (float) Math.hypot(points.get(i).x - event.getX(), points.get(i).y - event.getY());
                    if (distance < best) { best = distance; selectedIndex = i; }
                }
                invalidate();
                return true;
            }
            return true;
        }

        ArrayList<PointF> projectedPoints() {
            ArrayList<PointF> out = new ArrayList<>();
            TrackPoint origin = track.points.get(0);
            double latScale = 111320.0;
            double lonScale = Math.max(Math.cos(Math.toRadians(origin.latitude)) * 111320.0, 1);
            double minX = Double.MAX_VALUE, maxX = -Double.MAX_VALUE, minY = Double.MAX_VALUE, maxY = -Double.MAX_VALUE;
            ArrayList<PointF> raw = new ArrayList<>();
            for (TrackPoint point : track.points) {
                float x = (float) ((point.longitude - origin.longitude) * lonScale);
                float y = (float) (-(point.latitude - origin.latitude) * latScale);
                raw.add(new PointF(x, y));
                minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
            }
            float padding = dp(28);
            double scale = Math.min((getWidth() - padding * 2) / Math.max(maxX - minX, 1), (getHeight() - padding * 2) / Math.max(maxY - minY, 1));
            for (PointF point : raw) out.add(new PointF((float) (padding + (point.x - minX) * scale), (float) (padding + (maxY - point.y) * scale)));
            return out;
        }
    }

    private TrackData callAIForBrakeZones(ArrayList<TrackPoint> pts) throws Exception { String key = prefs.getString("apiKey", ""); if (key.isEmpty()) throw new IOException("missing key"); String base = prefs.getString("baseUrl", "https://api.tutujin.com/v1"); String model = prefs.getString("model", "claude-3-5-sonnet-20240620"); JSONArray arr = new JSONArray(); for (TrackPoint p : pts) { JSONObject o = new JSONObject(); o.put("latitude", p.latitude); o.put("longitude", p.longitude); arr.put(o); } JSONObject body = new JSONObject(); body.put("model", model); body.put("temperature", 0.1); body.put("max_tokens", 12000); JSONArray msgs = new JSONArray(); msgs.put(new JSONObject().put("role", "system").put("content", MAP_BRAKE_ZONE_PROMPT)); msgs.put(new JSONObject().put("role", "user").put("content", arr.toString())); body.put("messages", msgs); HttpURLConnection con = openAIConnection(base, key); con.getOutputStream().write(body.toString().getBytes(StandardCharsets.UTF_8)); String raw = readStream(con.getInputStream()); String content = new JSONObject(raw).getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content"); return parseTrack(extractJSONObject(content), "AI地图赛道"); }

    private TrackData callAIForImageTrack(Bitmap source, PointF finishPoint) throws Exception {
        String key = prefs.getString("apiKey", "").trim();
        if (key.isEmpty()) throw new IOException("missing key");
        String base = prefs.getString("baseUrl", "https://api.tutujin.com/v1");
        String model = prefs.getString("model", "claude-3-5-sonnet-20240620");
        Bitmap image = resizeBitmap(source, 1170);
        float scaleX = image.getWidth() / (float) Math.max(source.getWidth(), 1);
        float scaleY = image.getHeight() / (float) Math.max(source.getHeight(), 1);
        PointF uploadedFinish = new PointF(finishPoint.x * scaleX, finishPoint.y * scaleY);
        ByteArrayOutputStream jpeg = new ByteArrayOutputStream();
        image.compress(Bitmap.CompressFormat.JPEG, 82, jpeg);
        String imageBase64 = Base64.encodeToString(jpeg.toByteArray(), Base64.NO_WRAP);
        JSONObject body = new JSONObject();
        body.put("model", model);
        body.put("temperature", 0.1);
        body.put("max_tokens", 12000);
        JSONArray messages = new JSONArray();
        messages.put(new JSONObject().put("role", "system").put("content", new JSONArray().put(new JSONObject().put("type", "text").put("text", IMAGE_TRACK_PROMPT))));
        JSONArray userContent = new JSONArray();
        userContent.put(new JSONObject().put("type", "text").put("text", "终点像素坐标：x=" + (int) uploadedFinish.x + "，y=" + (int) uploadedFinish.y + "。图片尺寸：width=" + image.getWidth() + "，height=" + image.getHeight() + "。请把该点作为起终点附近参考。"));
        userContent.put(new JSONObject().put("type", "image_url").put("image_url", new JSONObject().put("url", "data:image/jpeg;base64," + imageBase64)));
        messages.put(new JSONObject().put("role", "user").put("content", userContent));
        body.put("messages", messages);
        HttpURLConnection con = openAIConnection(base, key);
        con.getOutputStream().write(body.toString().getBytes(StandardCharsets.UTF_8));
        String raw = readStream(con.getInputStream());
        String content = new JSONObject(raw).getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content");
        return convertImageTrack(new JSONObject(extractJSONObject(content)));
    }

    private HttpURLConnection openAIConnection(String base, String key) throws Exception {
        HttpURLConnection con = (HttpURLConnection) new URL(base + "/chat/completions").openConnection();
        con.setRequestMethod("POST");
        con.setRequestProperty("Authorization", "Bearer " + key);
        con.setRequestProperty("Content-Type", "application/json");
        con.setConnectTimeout(30000);
        con.setReadTimeout(180000);
        con.setDoOutput(true);
        return con;
    }

    private Bitmap resizeBitmap(Bitmap source, int maxDimension) {
        int max = Math.max(source.getWidth(), source.getHeight());
        if (max <= maxDimension) return source;
        float scale = maxDimension / (float) max;
        return Bitmap.createScaledBitmap(source, Math.round(source.getWidth() * scale), Math.round(source.getHeight() * scale), true);
    }

    private TrackData convertImageTrack(JSONObject aiTrack) throws Exception {
        JSONArray points = aiTrack.getJSONArray("points");
        TrackData track = new TrackData();
        track.name = aiTrack.optString("trackName", "AI生成赛道");
        track.length = aiTrack.optDouble("trackLength", 0);
        track.cornerCount = aiTrack.optInt("cornerCount", 0);
        double pixelLength = 0;
        for (int i = 1; i < points.length(); i++) {
            JSONObject a = points.getJSONObject(i - 1), b = points.getJSONObject(i);
            pixelLength += Math.hypot(b.optDouble("x") - a.optDouble("x"), b.optDouble("y") - a.optDouble("y"));
        }
        if (track.length <= 0) track.length = pixelLength * 0.5;
        double metersPerPixel = pixelLength > 1 ? track.length / pixelLength : 0.5;
        JSONObject start = points.getJSONObject(0);
        double originLat = latestLocation != null ? latestLocation.getLatitude() : 31.234567;
        double originLon = latestLocation != null ? latestLocation.getLongitude() : 121.345678;
        double latScale = 111320.0;
        double lonScale = Math.max(Math.cos(Math.toRadians(originLat)) * 111320.0, 1);
        for (int i = 0; i < points.length(); i++) {
            JSONObject point = points.getJSONObject(i);
            double east = (point.optDouble("x") - start.optDouble("x")) * metersPerPixel;
            double north = -(point.optDouble("y") - start.optDouble("y")) * metersPerPixel;
            track.points.add(new TrackPoint(originLat + north / latScale, originLon + east / lonScale, point.optDouble("speed", 50), point.optString("color", "green")));
        }
        return track;
    }

    private String extractJSONObject(String text) {
        String trimmed = text.trim();
        int start = trimmed.indexOf('{');
        int end = trimmed.lastIndexOf('}');
        return start >= 0 && end >= start ? trimmed.substring(start, end + 1) : trimmed;
    }
    private void markLocalBrakeZones(List<TrackPoint> pts) { for (int i = 0; i < pts.size(); i++) { TrackPoint p = pts.get(i); if (i % 24 < 5) pts.set(i, new TrackPoint(p.latitude, p.longitude, 35, "red")); else if (i % 24 < 9) pts.set(i, new TrackPoint(p.latitude, p.longitude, 48, "orange")); } }

    private int colorForTrack(String color, float alpha) {
        int channel = Math.min(255, Math.max(0, (int) (alpha * 255)));
        if ("red".equals(color)) return Color.argb(channel, 255, 12, 0);
        if ("orange".equals(color)) return Color.argb(channel, 255, 156, 0);
        return Color.argb(channel, 0, 255, 70);
    }

    private static final String IMAGE_TRACK_PROMPT = "你是专业卡丁车赛道分析AI。识别完整闭环赛道，按外-内-外原则生成平滑行车线，点间距约0.5米。只输出纯JSON，字段为trackName、trackLength、cornerCount、trackDescription、drivingTips、points。points每项包含x、y、speed、color、remark，color只能是green/orange/red。禁止输出JSON以外文字。";
    private static final String MAP_BRAKE_ZONE_PROMPT = "你是专业卡丁车赛道工程师。用户已经在地图实景底图上画出首尾相接的赛道中心线。保留整体形状，重采样约0.5米间距，生成speed和color，green=全油门，orange=松油，red=刹车区。只输出纯JSON，字段为trackName、trackLength、cornerCount、points；points每项包含latitude、longitude、speed、color、remark。禁止输出JSON以外文字。";

    final class AnimatedSwitchCheckBox extends CheckBox {
        final Paint switchPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        float knobProgress = 0f;
        ValueAnimator animator;

        AnimatedSwitchCheckBox(Context context) {
            super(context);
            setButtonDrawable(null);
            setGravity(Gravity.CENTER_VERTICAL);
            setSingleLine(true);
            setIncludeFontPadding(false);
            setTypeface(Typeface.DEFAULT_BOLD);
        }

        @Override public void setChecked(boolean checked) {
            boolean changed = checked != isChecked();
            super.setChecked(checked);
            float target = checked ? 1f : 0f;
            if (!changed || !isAttachedToWindow()) {
                knobProgress = target;
                invalidate();
                return;
            }
            if (animator != null) animator.cancel();
            animator = ValueAnimator.ofFloat(knobProgress, target);
            animator.setDuration(250);
            animator.setInterpolator(new OvershootInterpolator(1.0f));
            animator.addUpdateListener(animation -> {
                knobProgress = (float) animation.getAnimatedValue();
                invalidate();
            });
            animator.start();
        }

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float density = getResources().getDisplayMetrics().density;
            float switchWidth = 48f * density;
            float switchHeight = 26f * density;
            float knobSize = 22f * density;
            float right = getWidth() - 18f * density;
            float left = right - switchWidth;
            float top = (getHeight() - switchHeight) / 2f;
            RectF track = new RectF(left, top, right, top + switchHeight);
            int off = Color.parseColor("#333333");
            int on = Color.parseColor("#9C5F54");
            switchPaint.setStyle(Paint.Style.FILL);
            switchPaint.setColor(blendColor(off, on, Math.max(0f, Math.min(1f, knobProgress))));
            canvas.drawRoundRect(track, switchHeight / 2f, switchHeight / 2f, switchPaint);
            switchPaint.setColor(Color.WHITE);
            float knobLeft = left + 2f * density + (switchWidth - knobSize - 4f * density) * knobProgress;
            canvas.drawOval(new RectF(knobLeft, top + 2f * density, knobLeft + knobSize, top + 2f * density + knobSize), switchPaint);
        }

        int blendColor(int from, int to, float progress) {
            int a = (int) (Color.alpha(from) + (Color.alpha(to) - Color.alpha(from)) * progress);
            int r = (int) (Color.red(from) + (Color.red(to) - Color.red(from)) * progress);
            int g = (int) (Color.green(from) + (Color.green(to) - Color.green(from)) * progress);
            int b = (int) (Color.blue(from) + (Color.blue(to) - Color.blue(from)) * progress);
            return Color.argb(a, r, g, b);
        }
    }

    static final class GlassPanelDrawable extends Drawable {
        private final float radius;
        private final int alpha;
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint rim = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint glow = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF rect = new RectF();

        GlassPanelDrawable(float radius, int alpha) {
            this.radius = radius;
            this.alpha = Math.max(2, Math.min(64, alpha));
        }

        @Override public void draw(Canvas canvas) {
            Rect b = getBounds();
            rect.set(b.left + 1.5f, b.top + 1.5f, b.right - 1.5f, b.bottom - 1.5f);
            float corner = Math.min(radius, Math.min(rect.width(), rect.height()) / 2f);
            int topAlpha = Math.min(68, alpha + 18);
            int midAlpha = alpha;
            int bottomAlpha = Math.max(0, alpha / 5);

            fill.setStyle(Paint.Style.FILL);
            fill.setShader(new LinearGradient(0, rect.top, 0, rect.bottom,
                    new int[]{
                            Color.argb(topAlpha, 255, 255, 255),
                            Color.argb(midAlpha, 255, 255, 255),
                            Color.argb(bottomAlpha, 255, 255, 255)},
                    new float[]{0f, 0.44f, 1f}, Shader.TileMode.CLAMP));
            canvas.drawRoundRect(rect, corner, corner, fill);
            fill.setShader(null);

            glow.setStyle(Paint.Style.FILL);
            glow.setShader(new RadialGradient(rect.left + rect.width() * 0.20f, rect.top + rect.height() * 0.08f,
                    Math.max(rect.width(), rect.height()) * 0.74f,
                    new int[]{Color.argb(Math.min(42, alpha + 14), 255, 255, 255), Color.argb(7, 255, 255, 255), Color.TRANSPARENT},
                    new float[]{0f, 0.52f, 1f}, Shader.TileMode.CLAMP));
            canvas.drawRoundRect(rect, corner, corner, glow);

            glow.setShader(new RadialGradient(rect.right - rect.width() * 0.10f, rect.bottom - rect.height() * 0.08f,
                    Math.max(rect.width(), rect.height()) * 0.42f,
                    new int[]{Color.argb(28, 94, 215, 255), Color.argb(7, 94, 215, 255), Color.TRANSPARENT},
                    new float[]{0f, 0.52f, 1f}, Shader.TileMode.CLAMP));
            canvas.drawRoundRect(rect, corner, corner, glow);
            glow.setShader(null);

            RectF topShine = new RectF(rect.left + rect.width() * 0.10f, rect.top + rect.height() * 0.06f,
                    rect.right - rect.width() * 0.10f, rect.top + rect.height() * 0.50f);
            rim.setStyle(Paint.Style.STROKE);
            rim.setStrokeCap(Paint.Cap.ROUND);
            rim.setStrokeWidth(Math.max(1.6f, rect.height() * 0.030f));
            rim.setColor(Color.argb(220, 255, 255, 255));
            canvas.drawArc(topShine, 200, 140, false, rim);

            RectF leftCaustic = new RectF(rect.left + rect.width() * 0.04f, rect.top + rect.height() * 0.16f,
                    rect.left + rect.width() * 0.30f, rect.bottom - rect.height() * 0.12f);
            rim.setStrokeWidth(Math.max(1.2f, rect.height() * 0.020f));
            rim.setColor(Color.argb(120, 255, 255, 255));
            canvas.drawArc(leftCaustic, 105, 128, false, rim);

            rim.setStyle(Paint.Style.STROKE);
            rim.setStrokeWidth(1.8f);
            rim.setColor(Color.argb(210, 255, 255, 255));
            canvas.drawRoundRect(rect, corner, corner, rim);

            RectF inner = new RectF(rect.left + 3f, rect.top + 3f, rect.right - 3f, rect.bottom - 3f);
            rim.setStrokeWidth(1.0f);
            rim.setColor(Color.argb(70, 112, 220, 255));
            canvas.drawRoundRect(inner, Math.max(1f, corner - 3f), Math.max(1f, corner - 3f), rim);
        }

        @Override public void setAlpha(int value) { fill.setAlpha(value); rim.setAlpha(value); glow.setAlpha(value); }
        @Override public void setColorFilter(android.graphics.ColorFilter colorFilter) { fill.setColorFilter(colorFilter); rim.setColorFilter(colorFilter); glow.setColorFilter(colorFilter); }
        @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
    }

    static final class TrackData {
        String name = "Track";
        String remoteId = "";
        double length;
        int cornerCount;
        final ArrayList<TrackPoint> points = new ArrayList<>();
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

    static final class TelemetrySample {
        final double latitude;
        final double longitude;
        final double speed;
        final String color;
        final double acceleration;
        final double longitudinalAcceleration;
        final double lateralAcceleration;
        final double lineDeviationMeters;

        TelemetrySample(double latitude, double longitude, double speed, String color, double acceleration, double longitudinalAcceleration, double lateralAcceleration, double lineDeviationMeters) {
            this.latitude = latitude;
            this.longitude = longitude;
            this.speed = speed;
            this.color = color;
            this.acceleration = acceleration;
            this.longitudinalAcceleration = longitudinalAcceleration;
            this.lateralAcceleration = lateralAcceleration;
            this.lineDeviationMeters = lineDeviationMeters;
        }

        JSONObject toJson() throws JSONException {
            return new JSONObject()
                    .put("latitude", latitude)
                    .put("longitude", longitude)
                    .put("speed", speed)
                    .put("color", color)
                    .put("acceleration", acceleration)
                    .put("longitudinalAcceleration", longitudinalAcceleration)
                    .put("lateralAcceleration", lateralAcceleration)
                    .put("lineDeviationMeters", lineDeviationMeters);
        }
    }

    final class DrivingLineOverlay extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        List<TrackPoint> track = new ArrayList<>();
        double renderDistance = 160;
        double opacity = 0.82;
        double widthMeters = 0.5;
        double brightness = 1.0;
        float verticalOffset = 0;

        DrivingLineOverlay(Context c) {
            super(c);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
            paint.setStrokeWidth(18);
        }

        void setTrack(List<TrackPoint> t) { track = t; invalidate(); }
        double getRenderDistance() { return renderDistance; }
        void setRenderDistance(double d) { renderDistance = d; invalidate(); }
        float getVerticalOffset() { return verticalOffset; }
        void setVerticalOffset(float v) { verticalOffset = v; invalidate(); }
        void setLineStyle(double opacity, double widthMeters, double brightness) { this.opacity = opacity; this.widthMeters = widthMeters; this.brightness = brightness; paint.setStrokeWidth(dp((float) Math.max(4, widthMeters * 36))); invalidate(); }

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            if (track.size() < 2) return;
            List<PointF> pts = projectTrack();
            for (int i = 0; i < pts.size() - 1; i++) {
                float baseAlpha = i < pts.size() * 0.45f ? 1f : Math.max(0.1f, 1f - (i / (float) pts.size()));
                float alpha = (float) (baseAlpha * opacity);
                paint.setColor(colorFor(track.get(i % track.size()).color, alpha));
                canvas.drawLine(pts.get(i).x, pts.get(i).y + verticalOffset, pts.get(i + 1).x, pts.get(i + 1).y + verticalOffset, paint);
            }
        }

        List<PointF> projectTrack() {
            TrackPoint origin = track.get(0);
            double latScale = 111320.0;
            double lonScale = Math.max(Math.cos(Math.toRadians(origin.latitude)) * 111320.0, 1.0);
            double metersPerPixel = Math.max(renderDistance / Math.max(getHeight() * 0.72, 1), 0.1);
            float centerX = getWidth() / 2f;
            float startY = getHeight() * 0.86f;
            ArrayList<PointF> result = new ArrayList<>();
            double distance = 0;
            for (int i = 0; i < track.size() && distance <= renderDistance; i++) {
                TrackPoint point = track.get(i);
                if (i > 0) distance += distanceMeters(track.get(i - 1), point);
                float x = centerX + (float) (((point.longitude - origin.longitude) * lonScale) / metersPerPixel);
                float y = startY - (float) (Math.abs((point.latitude - origin.latitude) * latScale) / metersPerPixel);
                result.add(new PointF(x, y));
            }
            if (result.size() < 2) {
                result.add(new PointF(centerX, startY));
                result.add(new PointF(centerX, startY - getHeight() * 0.55f));
            }
            return result;
        }

        int colorFor(String color, float alpha) {
            int channel = Math.min(255, Math.max(0, (int) (alpha * 255)));
            int boost = Math.min(255, Math.max(80, (int) (brightness * 255)));
            if ("red".equals(color)) return Color.argb(channel, boost, 0, 0);
            if ("orange".equals(color)) return Color.argb(channel, boost, Math.min(220, boost), 0);
            return Color.argb(channel, 0, boost, Math.min(90, boost));
        }
    }

}
