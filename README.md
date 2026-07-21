# Git Mirror Site Generator

This repository contains an automated setup to generate a fast, static HTML mirror of your public GitHub repositories using `stagit` and GitHub Actions.

## How to Fork and Deploy

Follow these steps to create and host your own version of this repository mirror.

### 1. Fork the Repository
Click the "Fork" button at the top right of this repository page to create a copy under your own GitHub account.

### 2. Enable GitHub Actions
GitHub automatically disables workflows in forked repositories for security reasons.
1. Navigate to the "Actions" tab in your forked repository.
2. Click the button that says "I understand my workflows, go ahead and enable them".

### 3. Configure GitHub Pages
1. Go to your repository "Settings".
2. Click on "Pages" in the left sidebar.
3. Under "Build and deployment", set the source to "GitHub Actions" (or the specific deployment branch, depending on how your workflow file is configured to upload the `./site` directory).

### 4. Trigger the First Build
1. Go back to the "Actions" tab.
2. Select the build/deploy workflow from the left sidebar.
3. Click "Run workflow" to fetch your repositories, generate the HTML, and deploy the site.

## Customization

You can easily customize the site to fit your needs:

*   **Filter Repositories:** Open `build.sh` and look for the `gh repo list` command. You can edit the `select` statement to exclude specific repositories (e.g., hiding forks or specific project names).
*   **Styling & Assets:** Replace or edit the files inside the `assets/` directory (`style.css`, `logo.png`, `favicon.png`) to apply your own branding.
*   **Custom Domain:** If you are using a custom domain, simply create a file named `CNAME` in the root of the repository containing your domain name. The build script will automatically copy it to the site output.

## License
This project is open-source and available under the MIT License.