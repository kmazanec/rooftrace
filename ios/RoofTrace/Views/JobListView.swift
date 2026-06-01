import SwiftUI

struct JobListView: View {
    @Bindable var router: AppRouter
    @State private var model: JobListViewModel

    init(api: any APIClientProtocol, authStore: AuthStore, router: AppRouter) {
        _model = State(initialValue: JobListViewModel(api: api, authStore: authStore))
        self.router = router
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.CC.chalk.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(
                        eyebrow: "Home",
                        title: "Jobs",
                        subtitle: "Review every roof measurement from newest to oldest."
                    )

                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 96)
            }
            .refreshable {
                await model.refresh()
            }

            newMeasurementButton
        }
        .navigationTitle("RoofTrace")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.state == .idle {
                await model.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            skeletonRows
        case .loaded(let jobs):
            if jobs.isEmpty {
                EmptyStateView {
                    router.push(.createJob)
                }
            } else {
                rows(jobs)
            }
        case .error(let message, let stale):
            VStack(spacing: 12) {
                InlineErrorBlock(message: message)
                Button("Try again") {
                    Task { await model.refresh() }
                }
                .font(.RoofTrace.button)
                .foregroundStyle(Color.CC.blue)
                .frame(minHeight: 44)

                if stale.isEmpty {
                    EmptyStateView {
                        router.push(.createJob)
                    }
                } else {
                    rows(stale)
                }
            }
        }
    }

    private var skeletonRows: some View {
        VStack(spacing: 12) {
            ForEach(Self.skeletonJobs) { job in
                JobRow(job: job, isSkeleton: true)
            }
        }
        .accessibilityLabel("Loading jobs")
    }

    private func rows(_ jobs: [JobSummary]) -> some View {
        VStack(spacing: 12) {
            ForEach(jobs) { job in
                Button {
                    router.push(route(for: job.status, jobID: job.id))
                } label: {
                    JobRow(job: job)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var newMeasurementButton: some View {
        Button {
            router.push(.createJob)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                Text("New measurement")
                    .font(.RoofTrace.button)
            }
            .foregroundStyle(Color.CC.chalk)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(Color.CC.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private static let skeletonJobs: [JobSummary] = [
        JobSummary(
            id: "skeleton-1",
            address: "123 Main Street",
            status: .processing(.fetchingImagery),
            ready: false,
            totalAreaSqFt: nil,
            shareToken: nil,
            createdAt: Date()
        ),
        JobSummary(
            id: "skeleton-2",
            address: "456 Oak Avenue",
            status: .ready(ReportLocator(jobID: "skeleton-2", shareToken: nil)),
            ready: true,
            totalAreaSqFt: 1280,
            shareToken: nil,
            createdAt: Date()
        ),
        JobSummary(
            id: "skeleton-3",
            address: "789 Pine Road",
            status: .pending,
            ready: false,
            totalAreaSqFt: nil,
            shareToken: nil,
            createdAt: Date()
        )
    ]
}

extension JobSummary: Identifiable {}
