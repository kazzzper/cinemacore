package com.cinemacore.app.ui.search

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cinemacore.app.R
import com.cinemacore.app.domain.LoadState
import com.cinemacore.app.domain.Subject
import com.cinemacore.app.ui.CinemacoreViewModel
import com.cinemacore.app.ui.components.PosterGrid
import com.cinemacore.app.ui.components.StateView
import com.cinemacore.app.ui.theme.CinemaColors
import com.cinemacore.app.ui.theme.CinemaShape
import com.cinemacore.app.ui.theme.CinemaSpacing

@Composable
fun SearchScreen(
    app: CinemacoreViewModel,
    onOpenDetail: (Subject) -> Unit,
    modifier: Modifier = Modifier,
) {
    val viewModel: SearchViewModel = viewModel(
        key = "search-${app.repositoryGeneration}",
        factory = SearchViewModel.factory(app.repository),
    )
    var query by rememberSaveable { mutableStateOf("") }
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current

    fun submitQuery(value: String) {
        query = value
        keyboard?.hide()
        focus.clearFocus()
        viewModel.submit(value)
    }

    // A restored query belongs to the new holder after a source change, so it
    // is submitted again. A blank query clears results left by a previous tab
    // visit, which keeps the field and the grid in agreement.
    LaunchedEffect(viewModel) {
        if (query.isBlank()) viewModel.clear() else viewModel.submit(query)
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(CinemaColors.Background),
    ) {
        Text(
            text = stringResource(R.string.search_title),
            style = MaterialTheme.typography.headlineMedium,
            color = CinemaColors.TextPrimary,
            modifier = Modifier.padding(
                start = CinemaSpacing.screenHorizontal,
                end = CinemaSpacing.screenHorizontal,
                top = CinemaSpacing.x4,
                bottom = CinemaSpacing.x2,
            ),
        )
        SearchField(
            query = query,
            onQueryChange = { value ->
                query = value
                if (value.isBlank()) viewModel.clear() else viewModel.queryChanged(value)
            },
            onClear = {
                query = ""
                keyboard?.hide()
                focus.clearFocus()
                viewModel.clear()
            },
            onSubmit = { submitQuery(query) },
            modifier = Modifier.padding(horizontal = CinemaSpacing.screenHorizontal),
        )
        Spacer(Modifier.height(CinemaSpacing.x3))
        Box(
            Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
            val state = viewModel.state
            if (state == LoadState.Idle) {
                SearchIdle(Modifier.fillMaxSize())
            } else {
                StateView(
                    state = state,
                    emptyTitle = stringResource(R.string.search_empty_title),
                    emptyMessage = stringResource(R.string.search_empty_message),
                    loadingMessage = stringResource(R.string.search_loading),
                    onRetry = { viewModel.submit(query) },
                    modifier = Modifier.fillMaxSize(),
                ) { subjects ->
                    SearchResults(
                        subjects = subjects,
                        suggestions = viewModel.suggestions,
                        onSuggestion = { submitQuery(it) },
                        onOpenDetail = onOpenDetail,
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    onClear: () -> Unit,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        modifier = modifier.fillMaxWidth(),
        singleLine = true,
        placeholder = { Text(stringResource(R.string.search_field_placeholder)) },
        leadingIcon = {
            Icon(
                imageVector = Icons.Filled.Search,
                contentDescription = null,
            )
        },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = onClear) {
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = stringResource(R.string.search_clear),
                    )
                }
            }
        },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
        shape = RoundedCornerShape(CinemaShape.medium),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = CinemaColors.TextPrimary,
            unfocusedTextColor = CinemaColors.TextPrimary,
            cursorColor = CinemaColors.Brand,
            focusedContainerColor = CinemaColors.Surface,
            unfocusedContainerColor = CinemaColors.Surface,
            focusedBorderColor = CinemaColors.Brand,
            unfocusedBorderColor = CinemaColors.Separator,
            focusedPlaceholderColor = CinemaColors.TextSecondary,
            unfocusedPlaceholderColor = CinemaColors.TextSecondary,
        ),
    )
}

@Composable
private fun SearchIdle(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.padding(CinemaSpacing.x6),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            imageVector = Icons.Filled.Search,
            contentDescription = null,
            tint = CinemaColors.TextSecondary,
            modifier = Modifier.size(44.dp),
        )
        Spacer(Modifier.height(CinemaSpacing.x4))
        Text(
            text = stringResource(R.string.search_idle_title),
            style = MaterialTheme.typography.titleLarge,
            color = CinemaColors.TextPrimary,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(CinemaSpacing.x2))
        Text(
            text = stringResource(R.string.search_idle_message),
            style = MaterialTheme.typography.bodyMedium,
            color = CinemaColors.TextSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SearchResults(
    subjects: List<Subject>,
    suggestions: List<String>,
    onSuggestion: (String) -> Unit,
    onOpenDetail: (Subject) -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        if (suggestions.isNotEmpty()) {
            LazyRow(
                contentPadding = PaddingValues(
                    horizontal = CinemaSpacing.screenHorizontal,
                    vertical = CinemaSpacing.x2,
                ),
                horizontalArrangement = Arrangement.spacedBy(CinemaSpacing.x2),
            ) {
                itemsIndexed(
                    items = suggestions,
                    key = { index, suggestion -> "suggestion-$index-$suggestion" },
                ) { _, suggestion ->
                    Surface(
                        onClick = { onSuggestion(suggestion) },
                        modifier = Modifier.heightIn(min = 48.dp),
                        shape = CircleShape,
                        color = CinemaColors.SurfaceElevated,
                        contentColor = CinemaColors.TextSecondary,
                    ) {
                        Text(
                            text = suggestion,
                            style = MaterialTheme.typography.labelMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(
                                horizontal = CinemaSpacing.x3,
                                vertical = CinemaSpacing.x2,
                            ),
                        )
                    }
                }
            }
        }
        PosterGrid(
            subjects = subjects,
            onSubjectClick = onOpenDetail,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
        )
    }
}
