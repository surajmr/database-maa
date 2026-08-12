# Lab 2: Configure Full Stack DR for the AI Workload

## Introduction

Configure Full Stack DR for the AI application from Lab 1. Keep the original Ashburn Cloud Shell session available. The configuration creates DR Protection Groups and DR plans for the primary and standby regions. It configures the Autonomous AI Database as a snapshot standby for DR Drill operations.

Run the commands from the Ashburn Cloud Shell used in Lab 1.

**Before you begin:** Complete Lab 1 and keep the original Ashburn Cloud Shell session available.

The AI application runs in the Kubernetes namespace `ai-fsdr-lab`. Full Stack DR protects and restores the OKE resources in this namespace.

Estimated Time: 15 minutes

### Objectives

In this lab, you will:

- Run the Full Stack DR snapshot standby configuration script.
- Confirm that the configuration completes successfully.
- Verify the DR protection groups and DR plans in the OCI Console.

## Task 1: Configure Full Stack DR

1. In the Ashburn Cloud Shell, change to the application directory created in Lab 1.

    Run:

    ```bash
    <copy>
    cd ~/oci-ai-resiliency-lab
    </copy>
    ```

2. Run the Full Stack DR snapshot standby configuration script.

    In the Ashburn Cloud Shell, run:

    ```bash
    <copy>
    python3 scripts/configure-fsdr-snapshot-standby.py
    </copy>
    ```

    ![Run the Full Stack DR snapshot standby configuration script](./images/run-full-stack-dr-snapshot-standby.png)

    The script takes approximately 10 minutes. While it runs, continue to **Task 2: Monitor the Configuration in the OCI Console**. Keep the Ashburn Cloud Shell tab open. Return here when the script finishes. Confirm that it returns to the shell prompt and displays the protection group and plan OCIDs. The script performs these actions:

    - Creates a DR protection group in the primary region.
    - Creates a DR protection group in the standby region.
    - Associates the protection groups and assigns their primary and standby roles.
    - Adds the primary OKE cluster, primary ATP, and Ollama volume group to the primary DR protection group.
    - Adds the standby OKE cluster and standby ATP to the standby DR protection group.
    - Creates Switchover, Failover, and Start Drill plans in the standby DR protection group.

    A successful run displays the OCIDs for the primary and standby protection groups and the three plans.

    ![Full Stack DR configuration script completed successfully](./images/full-stack-dr-configuration-complete.png)

## Task 2: Monitor the Configuration in the OCI Console

1. While the script runs, open two additional OCI Console tabs. Set one to **Ashburn** and the other to **Phoenix**. Keep the Ashburn Cloud Shell tab open. In each Console tab, select **Migration & Recovery**, then **Recovery**, and then **Disaster Recovery**.

2. In both OCI Console tabs, change to the compartment assigned to you. Expand the root compartment, select **Livelabs**, and then select your assigned compartment.

3. Open **DR Protection groups** in each Console tab and monitor the pages as the primary and standby protection groups are created. Refresh the Console tabs periodically if the resources do not appear immediately; do not refresh the Cloud Shell tab. Verify the region-specific names:

    - **Ashburn:** `fsdr-rag-primary-xxxxx`
    - **Phoenix:** `fsdr-rag-standby-xxxxx`

    The `xxxxx` suffix is generated for your environment and may differ from the examples.

    Verify the protection group roles. The `fsdr-rag-primary-xxxxx` protection group shows the **Primary** role, and the `fsdr-rag-standby-xxxxx` protection group shows the **Standby** role.

    ![Ashburn Full Stack DR protection groups](./images/ashburn-full-stack-dr-protection-groups.png)

    ![Phoenix Full Stack DR protection groups](./images/phoenix-full-stack-dr-protection-groups.png)

4. As the configuration progresses, verify that the protection groups contain the expected AI workload resources as members.

    - In the Ashburn region, select `fsdr-rag-primary-xxxxx` and open the **Members** tab. Confirm that it contains the primary OKE cluster, primary ATP, and Ollama block volume group.

    ![Ashburn Full Stack DR protection groups members](./images/ashburn-full-stack-dr-protection-groups-members.png)

    - In the Phoenix region, select `fsdr-rag-standby-xxxxx` and open the **Members** tab. Confirm that it contains the standby OKE cluster and standby ATP.

    ![Phoenix Full Stack DR protection groups members](./images/phoenix-full-stack-dr-protection-groups-members.png)

5. After you confirm successful completion in the Ashburn Cloud Shell, use the Phoenix Console tab to open the plans for the **standby DR protection group**. Confirm that the following plans are available:

    ![Full Stack DR plans](./images/full-stack-dr-plans.png)

    **Expected recovery plans**

    | Plan type | Plan name |
    | --- | --- |
    | Switchover | `fsdr-rag-xxxxx-switchover` |
    | Failover | `fsdr-rag-xxxxx-failover` |
    | Start Drill | `fsdr-rag-xxxxx-start-drill` |

    The `xxxxx` portion is generated for your environment and may differ from the example.

6. Open each plan and review its task groups. Expand the groups to understand the order of operations. Do not start or execute a plan.

    A plan group is an ordered collection of recovery tasks that Full Stack DR executes as part of a plan. Full Stack DR creates the plans in the standby DR protection group. You can create plans, run plan prechecks, and execute plans only from the standby DR protection group.

    Each plan group contains individual plan steps. Full Stack DR generates these steps from the members and dependencies added to the DR protection group, so the steps can differ between environments.

    At a high level, expect the following plan types and task categories:

    | Plan type | Purpose | Expected task categories |
    | --- | --- | --- |
    | **Switchover** | Planned transition from the Ashburn primary environment to the Phoenix standby environment. | Prechecks, database and application role transitions, OKE and storage operations, and post-transition validation. |
    | **Failover** | Recovery when the Ashburn primary environment is unavailable. | Recovery prechecks, standby activation, application and database recovery, OKE and storage operations, and validation. |
    | **Start Drill** | Test the recovery workflow without changing the production role of the application. | Prechecks, drill-specific database and application operations, OKE and storage actions, and application validation. |

    The following console views show the task groups generated for each plan type:

    **Switchover plan**

    ![Switchover plan groups in the standby DR protection group](./images/fsdr-switchover-plan-groups.png)

    **Failover plan**

    ![Failover plan groups in the standby DR protection group](./images/fsdr-failover-plan-groups.png)

    **Start Drill plan**

    ![Start Drill plan groups in the standby DR protection group](./images/fsdr-start-drill-plan-groups.png)


    **Workshop execution note:** We will run the **Start Drill** plan as part of this workshop in **Lab 3**. Do not execute it in Lab 2.

    **Stop Drill note:** After the **Start Drill** plan completes successfully, Full Stack DR allows you to create a **Stop Drill** plan to end the drill and restore the environment. Creating or running a **Stop Drill** plan is not part of this workshop.

    Do not click **Start**, **Execute**, or **Run Prechecks** for any plan in Lab 2. The **Start Drill** plan is executed in Lab 3.

You may now [proceed to the next lab](#next).

## Acknowledgements

* **Author** - Suraj Ramesh, Lead Principal Product Manager, Oracle Database High Availability (HA), Scalability and Maximum Availability Architecture (MAA)
* **Last Updated By/Date** - August 2026
