package com.cinemacore.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import com.cinemacore.app.ui.CinemacoreRoot
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.player.PlayerActivity
import com.cinemacore.app.ui.splash.SplashOverlay
import com.cinemacore.app.ui.theme.CinemacoreTheme

class MainActivity : ComponentActivity() {
    private val app: CinemacoreViewModel by viewModels {
        CinemacoreViewModel.factory((application as CinemacoreApp).container)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }

        setContent {
            CinemacoreTheme {
                val permissionLauncher = rememberLauncherForNotificationPermission()
                LaunchedEffect(Unit) {
                    if (
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(
                            this@MainActivity,
                            Manifest.permission.POST_NOTIFICATIONS,
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }
                SplashOverlay {
                    Surface(
                        modifier = Modifier.fillMaxSize(),
                        color = MaterialTheme.colorScheme.background,
                    ) {
                        CinemacoreRoot(
                            app = app,
                            onPlay = { request ->
                                startActivity(PlayerActivity.intent(this@MainActivity, request))
                            },
                        )
                    }
                }
            }
        }
    }
}

@androidx.compose.runtime.Composable
private fun rememberLauncherForNotificationPermission() =
    androidx.activity.compose.rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { /* Denial is allowed; the foreground-service notice still appears in Task Manager. */ }
