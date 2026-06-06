package com.example.gokartarline;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.graphics.drawable.*;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.*;
import android.location.*;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class MainActivity extends Activity {
    private static final int REQ_PERM = 7, REQ_IMPORT = 8;
    private TextureView cameraPreview;
    private DrivingLineOverlay overlay;
    private TextView status;
    private CameraDevice cameraDevice;
    private CameraCaptureSession cameraSession;
    private SharedPreferences prefs;
    private final ArrayList<TrackData> tracks = new ArrayList<>();
    private int selectedTrack = -1;
    private double renderDistance = 160;
    private float lineHeight = 0;
    private boolean lowHeatMode = true;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("gokart", MODE_PRIVATE);
        renderDistance = Double.longBitsToDouble(prefs.getLong("renderDistance", Double.doubleToRawLongBits(160)));
        lineHeight = prefs.getFloat("lineHeight", 0);
        lowHeatMode = prefs.getBoolean("lowHeat", true);
        loadTracks();
        buildMainUi();
        if (tracks.isEmpty()) loadSampleTrack(); else selectTrack(Math.max(0, prefs.getInt("selectedTrack", 0)));
        requestCameraIfNeeded();
    }

    private void buildMainUi() {
        FrameLayout root = new FrameLayout(this);
        cameraPreview = new TextureView(this);
        cameraPreview.setOpaque(false);
        cameraPreview.setAlpha(0.86f);
        overlay = new DrivingLineOverlay(this);
        overlay.setRenderDistance(renderDistance);
        overlay.setVerticalOffset(lineHeight);
        root.addView(new LiquidBackdropView(this), new FrameLayout.LayoutParams(-1, -1));
        root.addView(cameraPreview, new FrameLayout.LayoutParams(-1, -1));
        root.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setTextSize(17);
        status.setPadding(dp(20), dp(12), dp(20), dp(12));
        status.setShadowLayer(dp(6), 0, dp(1), Color.argb(150, 0, 74, 105));
        status.setBackground(glassPanel(999, 18));
        status.setElevation(dp(14));
        FrameLayout.LayoutParams statusParams = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.START);
        statusParams.setMargins(dp(14), dp(14), dp(14), dp(14));
        root.addView(status, statusParams);
        LinearLayout bar = glassContainer(999, 12);
        bar.setGravity(Gravity.CENTER);
        bar.setPadding(dp(10), dp(8), dp(10), dp(8));
        addButton(bar, "Import", v -> importTrack());
        addButton(bar, "Tracks", v -> showTrackList());
        addButton(bar, "Map Draw", v -> showMapDrawer());
        addButton(bar, "AI", v -> showAISettings());
        addButton(bar, "Settings", v -> showSettings());
        FrameLayout.LayoutParams barParams = new FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        barParams.setMargins(dp(18), dp(18), dp(18), dp(18));
        root.addView(bar, barParams);
        setContentView(root);
    }

    private void addButton(LinearLayout parent, String text, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setText(text);
        applyGlassButton(b);
        b.setOnClickListener(listener);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, dp(56));
        lp.setMargins(dp(6), 0, dp(6), 0);
        parent.addView(b, lp);
    }


    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private Drawable glassPanel(float radiusDp, int alpha) {
        return new GlassPanelDrawable(dp(radiusDp), alpha);
    }

    private LinearLayout glassContainer(float radiusDp, int alpha) {
        LinearLayout layout = new LinearLayout(this);
        layout.setBackground(glassPanel(radiusDp, alpha));
        layout.setElevation(dp(10));
        return layout;
    }

    private void applyGlassButton(Button button) {
        button.setAllCaps(false);
        button.setTextColor(Color.WHITE);
        button.setTextSize(14);
        button.setMinHeight(dp(48));
        button.setMinWidth(dp(108));
        button.setPadding(dp(18), 0, dp(18), 0);
        StateListDrawable states = new StateListDrawable();
        states.addState(new int[]{android.R.attr.state_pressed}, glassPanel(999, 42));
        states.addState(new int[]{}, glassPanel(999, 14));
        button.setBackground(states);
        button.setElevation(dp(6));
    }

    private AlertDialog showGlassDialog(AlertDialog dialog) {
        dialog.setOnShowListener(d -> {
            Window window = dialog.getWindow();
            if (window != null) {
                window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
                View decor = window.getDecorView();
                decor.setPadding(dp(12), dp(12), dp(12), dp(12));
                decor.setBackground(glassPanel(36, 24));
                decor.setElevation(dp(16));
            }
            Button positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            Button negative = dialog.getButton(AlertDialog.BUTTON_NEGATIVE);
            Button neutral = dialog.getButton(AlertDialog.BUTTON_NEUTRAL);
            if (positive != null) applyGlassButton(positive);
            if (negative != null) applyGlassButton(negative);
            if (neutral != null) applyGlassButton(neutral);
        });
        dialog.show();
        return dialog;
    }

    private LinearLayout glassDialogBox() {
        LinearLayout box = glassContainer(32, 14);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(24), dp(18), dp(24), dp(12));
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
        else showNoCameraBackground("No camera permission: preview mode");
    }

    private void showNoCameraBackground(String message) {
        cameraPreview.setBackgroundColor(Color.rgb(18, 18, 18));
        setStatus(message);
    }

    private void setStatus(String message) {
        status.setText(message + "\nLine " + (int) renderDistance + "m | Height " + (int) lineHeight + "px | " + (lowHeatMode ? "720p" : "1080p"));
    }

    private void importTrack() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json");
        startActivityForResult(intent, REQ_IMPORT);
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_IMPORT && resultCode == RESULT_OK && data != null) {
            try { addTrack(parseTrack(readUri(data.getData()), "Imported Track")); toast("Import OK"); }
            catch (Exception e) { toast("Import failed: " + e.getMessage()); }
        }
    }

    private String readUri(Uri uri) throws Exception { try (InputStream in = getContentResolver().openInputStream(uri)) { return readStream(in); } }
    private String readAsset(String name) throws Exception { try (InputStream in = getAssets().open(name)) { return readStream(in); } }
    private String readStream(InputStream in) throws Exception { ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] b = new byte[8192]; int n; while ((n = in.read(b)) != -1) out.write(b, 0, n); return out.toString(StandardCharsets.UTF_8.name()); }

    private void loadSampleTrack() { try { addTrack(parseTrack(readAsset("SampleTrack.json"), "Sample Track")); } catch (Exception e) { toast("Sample failed: " + e.getMessage()); } }

    private TrackData parseTrack(String json, String fallbackName) throws Exception {
        JSONObject obj = new JSONObject(json);
        TrackData t = new TrackData();
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
    private void selectTrack(int index) { if (index < 0 || index >= tracks.size()) return; selectedTrack = index; overlay.setTrack(tracks.get(index).points); prefs.edit().putInt("selectedTrack", index).apply(); setStatus("Track: " + tracks.get(index).name + " | " + tracks.get(index).points.size() + " pts"); }

    private void showTrackList() {
        String[] names = new String[tracks.size()];
        for (int i = 0; i < tracks.size(); i++) names[i] = tracks.get(i).name + " | " + tracks.get(i).points.size() + " pts";
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Track Manager").setItems(names, (d, which) -> selectTrack(which)).setPositiveButton("Rename", (d, w) -> renameSelected()).setNegativeButton("Delete", (d, w) -> deleteSelected()).setNeutralButton("Close", null).create();
        showGlassDialog(dialog);
    }

    private void renameSelected() { if (selectedTrack < 0) return; EditText input = new EditText(this); input.setText(tracks.get(selectedTrack).name); showGlassDialog(new AlertDialog.Builder(this).setTitle("Rename").setView(input).setPositiveButton("Save", (d, w) -> { tracks.get(selectedTrack).name = input.getText().toString(); saveTracks(); selectTrack(selectedTrack); }).create()); }
    private void deleteSelected() { if (selectedTrack < 0) return; tracks.remove(selectedTrack); selectedTrack = Math.min(selectedTrack, tracks.size() - 1); saveTracks(); if (selectedTrack >= 0) selectTrack(selectedTrack); else overlay.setTrack(new ArrayList<>()); }

    private void showSettings() {
        LinearLayout box = glassDialogBox();
        SeekBar distance = new SeekBar(this); distance.setMax(170); distance.setProgress((int) renderDistance - 30); box.addView(label("Render distance 30-200m")); box.addView(distance);
        SeekBar height = new SeekBar(this); height.setMax(160); height.setProgress((int) (lineHeight + 80)); box.addView(label("Line height -80 to 80px")); box.addView(height);
        CheckBox low = new CheckBox(this); low.setText("720p low heat mode (off = 1080p)"); low.setChecked(lowHeatMode); box.addView(low);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("Settings").setView(box).setPositiveButton("Save", (d, w) -> { renderDistance = 30 + distance.getProgress(); lineHeight = height.getProgress() - 80; lowHeatMode = low.isChecked(); overlay.setRenderDistance(renderDistance); overlay.setVerticalOffset(lineHeight); prefs.edit().putLong("renderDistance", Double.doubleToRawLongBits(renderDistance)).putFloat("lineHeight", lineHeight).putBoolean("lowHeat", lowHeatMode).apply(); restartCamera(); setStatus("Settings saved"); }).create());
    }
    private TextView label(String s) { TextView v = new TextView(this); v.setText(s); v.setTextSize(16); v.setTextColor(Color.WHITE); v.setPadding(0, dp(10), 0, dp(4)); return v; }

    private void showAISettings() {
        LinearLayout box = glassDialogBox();
        EditText key = new EditText(this); key.setHint("AI API Key"); key.setText(prefs.getString("apiKey", ""));
        EditText base = new EditText(this); base.setHint("Base URL"); base.setText(prefs.getString("baseUrl", "https://api.openai.com/v1"));
        EditText model = new EditText(this); model.setHint("Model"); model.setText(prefs.getString("model", "gpt-4.1-mini"));
        box.addView(key); box.addView(base); box.addView(model);
        showGlassDialog(new AlertDialog.Builder(this).setTitle("AI Settings").setView(box).setPositiveButton("Save", (d, w) -> prefs.edit().putString("apiKey", key.getText().toString()).putString("baseUrl", base.getText().toString()).putString("model", model.getText().toString()).apply()).create());
    }

    private void showMapDrawer() { setContentView(new MapDrawerView(this)); }
    private void backHome() { buildMainUi(); if (selectedTrack >= 0) selectTrack(selectedTrack); requestCameraIfNeeded(); }

    private void saveTracks() { try { JSONArray arr = new JSONArray(); for (TrackData t : tracks) { JSONObject o = new JSONObject(); o.put("trackName", t.name); o.put("trackLength", t.length); o.put("cornerCount", t.cornerCount); JSONArray pts = new JSONArray(); for (TrackPoint p : t.points) { JSONObject po = new JSONObject(); po.put("latitude", p.latitude); po.put("longitude", p.longitude); po.put("speed", p.speed); po.put("color", p.color); pts.put(po); } o.put("points", pts); arr.put(o); } prefs.edit().putString("tracks", arr.toString()).apply(); } catch (Exception ignored) {} }
    private void loadTracks() { try { String raw = prefs.getString("tracks", null); if (raw == null) return; JSONArray arr = new JSONArray(raw); for (int i = 0; i < arr.length(); i++) tracks.add(parseTrack(arr.getJSONObject(i).toString(), "Local Track")); } catch (Exception ignored) {} }

    private void startCameraWhenReady() { cameraPreview.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() { public void onSurfaceTextureAvailable(SurfaceTexture s, int w, int h) { openCamera(s); } public void onSurfaceTextureSizeChanged(SurfaceTexture s, int w, int h) {} public boolean onSurfaceTextureDestroyed(SurfaceTexture s) { return true; } public void onSurfaceTextureUpdated(SurfaceTexture s) {} }); if (cameraPreview.isAvailable()) openCamera(cameraPreview.getSurfaceTexture()); }
    private void restartCamera() { if (cameraSession != null) cameraSession.close(); if (cameraDevice != null) cameraDevice.close(); startCameraWhenReady(); }
    private void openCamera(SurfaceTexture st) { try { CameraManager m = (CameraManager) getSystemService(CAMERA_SERVICE); String id = findBackCamera(m); if (id == null) { showNoCameraBackground("No camera: emulator preview mode"); return; } st.setDefaultBufferSize(lowHeatMode ? 1280 : 1920, lowHeatMode ? 720 : 1080); if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return; m.openCamera(id, new CameraDevice.StateCallback() { public void onOpened(CameraDevice c) { cameraDevice = c; startPreview(st); } public void onDisconnected(CameraDevice c) { c.close(); } public void onError(CameraDevice c, int e) { c.close(); showNoCameraBackground("Camera error: " + e); } }, null); } catch (Exception e) { showNoCameraBackground("No usable camera: " + e.getMessage()); } }
    private String findBackCamera(CameraManager m) throws CameraAccessException { for (String id : m.getCameraIdList()) { Integer f = m.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING); if (f != null && f == CameraCharacteristics.LENS_FACING_BACK) return id; } return m.getCameraIdList().length > 0 ? m.getCameraIdList()[0] : null; }
    private void startPreview(SurfaceTexture t) { try { Surface s = new Surface(t); CaptureRequest.Builder b = cameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW); b.addTarget(s); cameraDevice.createCaptureSession(Collections.singletonList(s), new CameraCaptureSession.StateCallback() { public void onConfigured(CameraCaptureSession session) { cameraSession = session; try { session.setRepeatingRequest(b.build(), null, null); } catch (Exception e) { showNoCameraBackground("Preview failed"); } } public void onConfigureFailed(CameraCaptureSession session) { showNoCameraBackground("Preview config failed"); } }, null); } catch (Exception e) { showNoCameraBackground("Preview failed: " + e.getMessage()); } }
    @Override protected void onDestroy() { super.onDestroy(); if (cameraSession != null) cameraSession.close(); if (cameraDevice != null) cameraDevice.close(); }

    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_LONG).show(); }
    private double computeLength(List<TrackPoint> pts) { double d = 0; for (int i = 1; i < pts.size(); i++) d += distanceMeters(pts.get(i - 1), pts.get(i)); return d; }
    private double distanceMeters(TrackPoint a, TrackPoint b) { double dLat = Math.toRadians(b.latitude - a.latitude), dLon = Math.toRadians(b.longitude - a.longitude), lat1 = Math.toRadians(a.latitude), lat2 = Math.toRadians(b.latitude); double h = Math.sin(dLat / 2) * Math.sin(dLat / 2) + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) * Math.sin(dLon / 2); return 6371000.0 * 2.0 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h)); }

    final class MapDrawerView extends LinearLayout {
        final DrawCanvas canvas; final EditText search;
        MapDrawerView(Context c) { super(c); setOrientation(VERTICAL); setPadding(dp(12), dp(12), dp(12), dp(12)); setBackgroundColor(Color.rgb(53, 120, 150)); search = new EditText(c); search.setHint("Search place, then draw track"); search.setTextColor(Color.WHITE); search.setHintTextColor(0xAAFFFFFF); search.setBackground(glassPanel(999, 28)); search.setPadding(dp(12), 0, dp(12), 0); Button find = new Button(c); find.setText("Search"); Button close = new Button(c); close.setText("Close Loop"); Button ai = new Button(c); ai.setText("AI Brake Zones"); Button home = new Button(c); home.setText("Back"); LinearLayout top = glassContainer(999, 28); top.setPadding(dp(10), dp(8), dp(10), dp(8)); top.addView(search, new LinearLayout.LayoutParams(0, dp(52), 1)); applyGlassButton(find); applyGlassButton(close); applyGlassButton(ai); applyGlassButton(home); top.addView(find); top.addView(close); top.addView(ai); top.addView(home); addView(top); canvas = new DrawCanvas(c); LinearLayout.LayoutParams canvasLp = new LinearLayout.LayoutParams(-1, 0, 1); canvasLp.setMargins(0, dp(12), 0, 0); addView(canvas, canvasLp); find.setOnClickListener(v -> searchPlace()); close.setOnClickListener(v -> canvas.closeLoop()); ai.setOnClickListener(v -> generateFromDrawing()); home.setOnClickListener(v -> backHome()); }
        void searchPlace() { try { List<Address> list = new Geocoder(MainActivity.this).getFromLocationName(search.getText().toString(), 1); if (list != null && !list.isEmpty()) { canvas.centerLat = list.get(0).getLatitude(); canvas.centerLon = list.get(0).getLongitude(); toast("Located; start drawing"); } } catch (Exception e) { toast("Search failed: " + e.getMessage()); } }
        void generateFromDrawing() { if (!canvas.closed()) { toast("Close loop first"); return; } ArrayList<TrackPoint> pts = canvas.toTrackPoints(); new Thread(() -> { try { TrackData t = callAIForBrakeZones(pts); runOnUiThread(() -> { addTrack(t); backHome(); }); } catch (Exception e) { TrackData t = new TrackData(); t.name = "Map Draw Track"; t.points.addAll(pts); t.length = computeLength(pts); markLocalBrakeZones(t.points); runOnUiThread(() -> { addTrack(t); toast("AI failed; local brake zones generated"); backHome(); }); } }).start(); }
    }

    final class DrawCanvas extends View { final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG); final ArrayList<PointF> drawn = new ArrayList<>(); double centerLat = 31.2304, centerLon = 121.4737; DrawCanvas(Context c) { super(c); p.setStrokeWidth(7); p.setStrokeCap(Paint.Cap.ROUND); p.setColor(Color.GREEN); } protected void onDraw(Canvas c) { c.drawColor(Color.rgb(18, 22, 24)); p.setStyle(Paint.Style.FILL); p.setTextSize(34); c.drawText("Draw mode: drag a closed track", 30, 50, p); p.setStyle(Paint.Style.STROKE); for (int i = 1; i < drawn.size(); i++) c.drawLine(drawn.get(i - 1).x, drawn.get(i - 1).y, drawn.get(i).x, drawn.get(i).y, p); } public boolean onTouchEvent(android.view.MotionEvent e) { if (e.getAction() == android.view.MotionEvent.ACTION_DOWN || e.getAction() == android.view.MotionEvent.ACTION_MOVE) { PointF pt = new PointF(e.getX(), e.getY()); if (drawn.isEmpty() || dist(drawn.get(drawn.size() - 1), pt) > 8) { drawn.add(pt); invalidate(); } return true; } return true; } void closeLoop() { if (drawn.size() > 2) { drawn.add(new PointF(drawn.get(0).x, drawn.get(0).y)); invalidate(); } } boolean closed() { return drawn.size() > 3 && dist(drawn.get(0), drawn.get(drawn.size() - 1)) < 20; } float dist(PointF a, PointF b) { return (float) Math.hypot(a.x - b.x, a.y - b.y); } ArrayList<TrackPoint> toTrackPoints() { ArrayList<TrackPoint> out = new ArrayList<>(); double mpp = 0.5, latScale = 111320.0, lonScale = Math.max(Math.cos(Math.toRadians(centerLat)) * 111320.0, 1); for (PointF pt : drawn) { double east = (pt.x - getWidth() / 2.0) * mpp; double north = (getHeight() / 2.0 - pt.y) * mpp; out.add(new TrackPoint(centerLat + north / latScale, centerLon + east / lonScale, 60, "green")); } return out; } }

    private TrackData callAIForBrakeZones(ArrayList<TrackPoint> pts) throws Exception { String key = prefs.getString("apiKey", ""); if (key.isEmpty()) throw new IOException("missing key"); String base = prefs.getString("baseUrl", "https://api.openai.com/v1"); String model = prefs.getString("model", "gpt-4.1-mini"); JSONArray arr = new JSONArray(); for (TrackPoint p : pts) { JSONObject o = new JSONObject(); o.put("latitude", p.latitude); o.put("longitude", p.longitude); arr.put(o); } JSONObject body = new JSONObject(); body.put("model", model); body.put("temperature", 0.1); body.put("max_tokens", 12000); JSONArray msgs = new JSONArray(); msgs.put(new JSONObject().put("role", "system").put("content", "Generate JSON for a closed kart track. points include latitude longitude speed color. color only green/orange/red. Mark red/orange before corners. Keep input shape. Output JSON only.")); msgs.put(new JSONObject().put("role", "user").put("content", arr.toString())); body.put("messages", msgs); HttpURLConnection con = (HttpURLConnection) new URL(base + "/chat/completions").openConnection(); con.setRequestMethod("POST"); con.setRequestProperty("Authorization", "Bearer " + key); con.setRequestProperty("Content-Type", "application/json"); con.setDoOutput(true); con.getOutputStream().write(body.toString().getBytes(StandardCharsets.UTF_8)); String raw = readStream(con.getInputStream()); String content = new JSONObject(raw).getJSONArray("choices").getJSONObject(0).getJSONObject("message").getString("content"); String json = content.substring(content.indexOf('{'), content.lastIndexOf('}') + 1); return parseTrack(json, "AI Map Track"); }
    private void markLocalBrakeZones(List<TrackPoint> pts) { for (int i = 0; i < pts.size(); i++) { TrackPoint p = pts.get(i); if (i % 24 < 5) pts.set(i, new TrackPoint(p.latitude, p.longitude, 35, "red")); else if (i % 24 < 9) pts.set(i, new TrackPoint(p.latitude, p.longitude, 48, "orange")); } }


    static final class LiquidBackdropView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF rect = new RectF();

        LiquidBackdropView(Context context) {
            super(context);
            line.setStyle(Paint.Style.STROKE);
            line.setStrokeCap(Paint.Cap.ROUND);
        }

        @Override protected void onDraw(Canvas canvas) {
            int w = Math.max(getWidth(), 1);
            int h = Math.max(getHeight(), 1);
            paint.setShader(new LinearGradient(0, 0, w, h,
                    new int[]{Color.rgb(221, 245, 255), Color.rgb(29, 181, 227), Color.rgb(0, 96, 221), Color.rgb(232, 246, 250)},
                    new float[]{0f, 0.34f, 0.72f, 1f}, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, w, h, paint);
            paint.setShader(new RadialGradient(w * 0.24f, h * 0.22f, w * 0.72f,
                    new int[]{Color.argb(190, 255, 255, 255), Color.argb(70, 158, 235, 255), Color.TRANSPARENT},
                    new float[]{0f, 0.45f, 1f}, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, w, h, paint);
            paint.setShader(new RadialGradient(w * 0.82f, h * 0.82f, w * 0.52f,
                    new int[]{Color.argb(135, 255, 255, 255), Color.argb(45, 63, 210, 255), Color.TRANSPARENT},
                    new float[]{0f, 0.48f, 1f}, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, w, h, paint);
            paint.setShader(null);
            line.setStrokeWidth(Math.max(18f, w * 0.035f));
            line.setColor(Color.argb(130, 255, 255, 255));
            rect.set(-w * 0.16f, h * 0.05f, w * 1.12f, h * 0.76f);
            canvas.drawArc(rect, 188, 98, false, line);
            line.setStrokeWidth(Math.max(26f, w * 0.046f));
            line.setColor(Color.argb(86, 180, 255, 218));
            rect.set(-w * 0.20f, h * 0.11f, w * 1.06f, h * 0.92f);
            canvas.drawArc(rect, 202, 105, false, line);
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

    final class DrivingLineOverlay extends View {
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        List<TrackPoint> track = new ArrayList<>();
        double renderDistance = 160;
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

        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            if (track.size() < 2) return;
            List<PointF> pts = projectTrack();
            for (int i = 0; i < pts.size() - 1; i++) {
                float alpha = i < pts.size() * 0.45f ? 0.82f : Math.max(0.1f, 1f - (i / (float) pts.size()));
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
            if ("red".equals(color)) return Color.argb(channel, 255, 0, 0);
            if ("orange".equals(color)) return Color.argb(channel, 255, 210, 0);
            return Color.argb(channel, 0, 255, 70);
        }
    }

}
