require "rails_helper"

RSpec.describe "Dev login", type: :request do
  let(:username) { "demo" }
  let(:password) { "correct-horse" }
  let(:digest) { BCrypt::Password.create(password) }

  around do |example|
    # dotenv-rails restores ENV to its pre-example snapshot after each example,
    # so setting these here is self-cleaning across examples.
    ENV["DEMO_USERNAME"] = username
    ENV["DEMO_PASSWORD_DIGEST"] = digest
    example.run
  end

  it "redirects an unauthenticated submit-page request to /login" do
    get new_job_path
    expect(response).to redirect_to(login_path)
  end

  it "logs in with correct credentials and redirects to the original destination" do
    get new_job_path # sets session[:return_to]
    post login_path, params: { username: username, password: password }
    expect(response).to redirect_to(new_job_path)

    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it "rejects wrong credentials with 200 + an error (not 401)" do
    post login_path, params: { username: username, password: "wrong" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Incorrect")
  end

  it "rejects a wrong username" do
    post login_path, params: { username: "intruder", password: password }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Incorrect")
  end

  it "logout clears the session and redirects to /login" do
    post login_path, params: { username: username, password: password }
    delete logout_path
    expect(response).to redirect_to(login_path)

    # Session cleared: the gated page redirects to login again.
    get new_job_path
    expect(response).to redirect_to(login_path)
  end

  describe "credential rotation (v1 trade-off, ADR-016)" do
    it "loses access after the digest rotates" do
      post login_path, params: { username: username, password: password }
      expect(response).to redirect_to(root_path) # no return_to set -> lands on root

      # Rotate DEMO_PASSWORD_DIGEST mid-session. The session flag set above is a
      # boolean, so the *current* session survives until reset — but a fresh
      # login attempt against the new digest with the old password must fail.
      ENV["DEMO_PASSWORD_DIGEST"] = BCrypt::Password.create("a-new-password")
      reset! # new session (simulates a redeploy dropping the cookie)
      post login_path, params: { username: username, password: password }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Incorrect")
    end
  end

  context "when the digest env var is malformed" do
    it "never authenticates" do
      ENV["DEMO_PASSWORD_DIGEST"] = "not-a-bcrypt-hash"
      post login_path, params: { username: username, password: password }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Incorrect")
    end
  end
end
